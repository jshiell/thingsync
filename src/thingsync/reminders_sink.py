"""Adapter: :class:`ReminderPayload` in, reminders in the Reminders app out.

The second and last module that touches the outside world.

**Commit policy.** Every write commits immediately (``commit=True``) rather than
batching behind one final commit. Batching is markedly faster on a first run,
but it makes a batch all-or-nothing, which contradicts the state store's rule
that mappings are persisted incrementally as writes succeed. A crash partway
through a first run must not leave created reminders unrecorded — that is the
duplication path — so correctness wins over speed here.
"""

from __future__ import annotations

import threading
from datetime import date

import EventKit
from Foundation import NSURL, NSCalendar, NSDate, NSDateComponents, NSRunLoop

from thingsync.mapping import uuid_from_marker
from thingsync.model import ReminderPayload

DEFAULT_TIMEOUT = 30.0


def date_components(value: date | None) -> NSDateComponents | None:
    """A date-only ``NSDateComponents``.

    Deliberately sets no time of day: a timed due date is a different thing to
    the Reminders app, and alarms are never set at all.
    """
    if value is None:
        return None

    components = NSDateComponents.alloc().init()
    components.setYear_(value.year)
    components.setMonth_(value.month)
    components.setDay_(value.day)
    components.setCalendar_(NSCalendar.currentCalendar())
    return components


def _pump(done: threading.Event, timeout: float = DEFAULT_TIMEOUT) -> bool:
    """Run the runloop until an EventKit completion handler fires.

    EventKit's fetches are asynchronous and deliver on the runloop, so a plain
    ``Event.wait()`` would deadlock.
    """
    deadline = NSDate.dateWithTimeIntervalSinceNow_(timeout)
    while not done.is_set() and NSDate.date().compare_(deadline) < 0:
        NSRunLoop.currentRunLoop().runMode_beforeDate_(
            "kCFRunLoopDefaultMode", NSDate.dateWithTimeIntervalSinceNow_(0.05)
        )
    return done.is_set()


class RemindersError(Exception):
    """A write to the Reminders store failed, or access was refused."""


class RemindersSink:
    """Create, update, complete and scan reminders in one target list."""

    def __init__(self, target_list: str, store=None):
        self.target_list = target_list
        self._store = store or EventKit.EKEventStore.alloc().init()
        self._calendar = None

    def request_access(self) -> None:
        """Ask for full access. Prompts the first time, on macOS 14+."""
        done = threading.Event()
        outcome: dict = {}

        def handler(granted, error):
            outcome["granted"] = bool(granted)
            outcome["error"] = error
            done.set()

        self._store.requestFullAccessToRemindersWithCompletion_(handler)
        if not _pump(done):
            raise RemindersError("timed out waiting for the Reminders permission prompt")
        if not outcome.get("granted"):
            raise RemindersError(
                f"Reminders access was not granted ({outcome.get('error')}); "
                "run `thingsync doctor` for the specifics"
            )

    def find_calendar(self):
        """The target list, or None if it does not exist. Never writes."""
        if self._calendar is not None:
            return self._calendar

        for candidate in self._store.calendarsForEntityType_(
            EventKit.EKEntityTypeReminder
        ):
            if candidate.title() == self.target_list:
                self._calendar = candidate
                return candidate
        return None

    def calendar(self):
        """The target list, created if it does not exist yet.

        Only called on the first real write: ``--dry-run`` must not leave an
        empty list behind as a side effect of looking.
        """
        existing = self.find_calendar()
        if existing is not None:
            return existing

        created = EventKit.EKCalendar.calendarForEntityType_eventStore_(
            EventKit.EKEntityTypeReminder, self._store
        )
        created.setTitle_(self.target_list)
        default = self._store.defaultCalendarForNewReminders()
        if default is None:
            raise RemindersError("no default Reminders list to create the target list in")
        created.setSource_(default.source())
        ok, error = self._store.saveCalendar_commit_error_(created, True, None)
        if not ok:
            raise RemindersError(f"could not create list {self.target_list!r}: {error}")

        self._calendar = created
        return created

    def scan_markers(self) -> dict[str, str]:
        """Map Things UUID to reminder identifier for everything we can prove is ours.

        This is what tells "the user deleted it" apart from "iCloud rotated the
        identifier", so it is never skipped. Only incomplete reminders are
        scanned: a reminder completed for a to-do that has since been reopened
        is deliberately left alone.
        """
        calendar = self.find_calendar()
        if calendar is None:
            # Nothing mirrored yet, and looking must not create the list.
            return {}

        predicate = self._store.predicateForIncompleteRemindersWithDueDateStarting_ending_calendars_(
            None, None, [calendar]
        )
        done = threading.Event()
        found: dict = {}

        def handler(reminders):
            found["reminders"] = reminders
            done.set()

        self._store.fetchRemindersMatchingPredicate_completion_(predicate, handler)
        if not _pump(done):
            raise RemindersError(f"timed out scanning list {self.target_list!r}")

        markers = {}
        for reminder in found.get("reminders") or []:
            url = reminder.URL()
            uuid = uuid_from_marker(url.absoluteString() if url else None)
            if uuid:
                markers[uuid] = reminder.calendarItemIdentifier()
        return markers

    def resolve_live(self, identifiers) -> set[str]:
        """Which cached identifiers still resolve. Synchronous, and cheap."""
        return {
            identifier
            for identifier in identifiers
            if self._store.calendarItemWithIdentifier_(identifier) is not None
        }

    def create(self, payload: ReminderPayload) -> str:
        reminder = EventKit.EKReminder.reminderWithEventStore_(self._store)
        reminder.setCalendar_(self.calendar())
        self._apply(reminder, payload)
        self._save(reminder)
        return reminder.calendarItemIdentifier()

    def update(self, identifier: str, payload: ReminderPayload) -> None:
        reminder = self._require(identifier)
        self._apply(reminder, payload)
        self._save(reminder)

    def complete(self, identifier: str) -> None:
        reminder = self._require(identifier)
        reminder.setCompleted_(True)
        self._save(reminder)

    def delete(self, identifier: str) -> None:
        reminder = self._require(identifier)
        ok, error = self._store.removeReminder_commit_error_(reminder, True, None)
        if not ok:
            raise RemindersError(f"could not delete reminder {identifier}: {error}")

    def _require(self, identifier: str):
        reminder = self._store.calendarItemWithIdentifier_(identifier)
        if reminder is None:
            raise RemindersError(f"no reminder with identifier {identifier}")
        return reminder

    def _apply(self, reminder, payload: ReminderPayload) -> None:
        reminder.setTitle_(payload.title)
        reminder.setNotes_(payload.notes or None)
        reminder.setURL_(NSURL.URLWithString_(payload.url))
        reminder.setDueDateComponents_(date_components(payload.due_date))
        reminder.setStartDateComponents_(date_components(payload.start_date))
        # Alarms are never set. startDateComponents alone does not notify, and an
        # alarm per mirrored to-do would be an avalanche.

    def _save(self, reminder) -> None:
        ok, error = self._store.saveReminder_commit_error_(reminder, True, None)
        if not ok:
            raise RemindersError(f"could not save reminder {reminder.title()!r}: {error}")
