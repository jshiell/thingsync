"""Adapters: :class:`ReminderPayload` in, reminders in the Reminders app out.

The second and last pair of modules that touch the outside world.

**Commit policy.** Every write commits immediately (``commit=True``) rather than
batching behind one final commit. Batching is markedly faster on a first run,
but it makes a batch all-or-nothing, which contradicts the state store's rule
that mappings are persisted incrementally as writes succeed. A crash partway
through a first run must not leave created reminders unrecorded — that is the
duplication path — so correctness wins over speed here.
"""

from __future__ import annotations

import threading
from dataclasses import dataclass
from datetime import date

import EventKit
from Foundation import NSDate, NSRunLoop, NSCalendar, NSDateComponents, NSURL

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


@dataclass(frozen=True)
class CalendarScan:
    """What one calendar's contents say, for one run.

    ``marked`` covers incomplete reminders only — the input ``planner.plan``
    needs. ``has_foreign_reminder`` is computed over *every* reminder,
    complete or not, since deleting a calendar deletes its completed
    reminders too, and the safety rule cannot ignore those.
    """

    calendar_id: str
    title: str
    marked: dict[str, str]
    has_foreign_reminder: bool


class CalendarManager:
    """Enumerate, create, rename and delete thingsync's Reminders lists, and
    scan their contents for markers.

    Kept separate from :class:`RemindersSink`: that class is about one
    reminder at a time, in an already-resolved calendar; this one is about
    the calendars themselves, which have no in-band identity marker of their
    own (see plan.md, "Why list identity is a harder problem").
    """

    def __init__(self, store):
        self._store = store

    def all_calendars(self) -> list:
        return list(self._store.calendarsForEntityType_(EventKit.EKEntityTypeReminder))

    def create(self, title: str):
        created = EventKit.EKCalendar.calendarForEntityType_eventStore_(
            EventKit.EKEntityTypeReminder, self._store
        )
        created.setTitle_(title)
        default = self._store.defaultCalendarForNewReminders()
        if default is None:
            raise RemindersError(f"no default Reminders list to create {title!r} in")
        created.setSource_(default.source())
        ok, error = self._store.saveCalendar_commit_error_(created, True, None)
        if not ok:
            raise RemindersError(f"could not create list {title!r}: {error}")
        return created

    def rename(self, calendar, title: str) -> None:
        calendar.setTitle_(title)
        ok, error = self._store.saveCalendar_commit_error_(calendar, True, None)
        if not ok:
            raise RemindersError(f"could not rename list to {title!r}: {error}")

    def delete(self, calendar) -> None:
        ok, error = self._store.removeCalendar_commit_error_(calendar, True, None)
        if not ok:
            raise RemindersError(f"could not delete list {calendar.title()!r}: {error}")

    def _fetch(self, predicate) -> list:
        done = threading.Event()
        found: dict = {}

        def handler(reminders):
            found["reminders"] = reminders
            done.set()

        self._store.fetchRemindersMatchingPredicate_completion_(predicate, handler)
        if not _pump(done):
            raise RemindersError("timed out scanning Reminders")
        return list(found.get("reminders") or [])

    def scan(self, calendars: list) -> list[CalendarScan]:
        """Every thingsync-relevant fact about ``calendars``' contents, in one
        pair of fetches rather than one pair per calendar."""
        incomplete = self._fetch(
            self._store.predicateForIncompleteRemindersWithDueDateStarting_ending_calendars_(
                None, None, calendars
            )
        )
        completed = self._fetch(
            self._store.predicateForCompletedRemindersWithCompletionDateStarting_ending_calendars_(
                NSDate.distantPast(), NSDate.distantFuture(), calendars
            )
        )

        marked: dict[str, dict[str, str]] = {}
        foreign: dict[str, bool] = {}

        for reminder in incomplete:
            calendar_id = reminder.calendar().calendarIdentifier()
            url = reminder.URL()
            uuid = uuid_from_marker(url.absoluteString() if url else None)
            if uuid:
                marked.setdefault(calendar_id, {})[uuid] = reminder.calendarItemIdentifier()
            else:
                foreign[calendar_id] = True

        for reminder in completed:
            calendar_id = reminder.calendar().calendarIdentifier()
            url = reminder.URL()
            if not uuid_from_marker(url.absoluteString() if url else None):
                foreign[calendar_id] = True

        return [
            CalendarScan(
                calendar_id=calendar.calendarIdentifier(),
                title=calendar.title(),
                marked=marked.get(calendar.calendarIdentifier(), {}),
                has_foreign_reminder=foreign.get(calendar.calendarIdentifier(), False),
            )
            for calendar in calendars
        ]


class RemindersSink:
    """Create, update, move and complete reminders, given an already-resolved
    calendar for each write. Calendar identity itself is CalendarManager's job."""

    def __init__(self, store=None):
        self._store = store or EventKit.EKEventStore.alloc().init()

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

    def resolve_live(self, identifiers) -> dict[str, str]:
        """Which cached identifiers still resolve, and which calendar each is
        actually in now — calendar-aware, so a reminder that moved (by hand,
        or because its to-do's project changed) is never mistaken for one
        that is still exactly where it was left."""
        result = {}
        for identifier in identifiers:
            reminder = self._store.calendarItemWithIdentifier_(identifier)
            if reminder is not None:
                result[identifier] = reminder.calendar().calendarIdentifier()
        return result

    def create(self, calendar_id: str, payload: ReminderPayload) -> str:
        reminder = EventKit.EKReminder.reminderWithEventStore_(self._store)
        reminder.setCalendar_(self._require_calendar(calendar_id))
        self._apply(reminder, payload)
        self._save(reminder)
        return reminder.calendarItemIdentifier()

    def update(self, identifier: str, payload: ReminderPayload) -> None:
        reminder = self._require(identifier)
        self._apply(reminder, payload)
        self._save(reminder)

    def move(self, identifier: str, calendar_id: str, payload: ReminderPayload) -> None:
        reminder = self._require(identifier)
        reminder.setCalendar_(self._require_calendar(calendar_id))
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

    def _require_calendar(self, calendar_id: str):
        calendar = self._store.calendarWithIdentifier_(calendar_id)
        if calendar is None:
            raise RemindersError(f"no calendar with identifier {calendar_id}")
        return calendar

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
