from datetime import date

import pytest

from thingsync.reminders_sink import date_components


def test_a_date_becomes_date_only_components():
    components = date_components(date(2026, 8, 25))

    assert (components.year(), components.month(), components.day()) == (2026, 8, 25)


def test_no_time_of_day_is_set():
    # A time would turn an all-day due date into a timed one, and timed reminders
    # behave differently in the Reminders app.
    components = date_components(date(2026, 8, 25))

    undefined = 0x7FFFFFFFFFFFFFFF  # NSDateComponentUndefined
    assert components.hour() == undefined
    assert components.minute() == undefined


def test_no_date_yields_no_components():
    assert date_components(None) is None


from thingsync.mapping import marker_url
from thingsync.model import ReminderPayload


@pytest.fixture
def live_sink():
    """A throwaway list, removed again afterwards."""
    from thingsync.reminders_sink import RemindersSink

    sink = RemindersSink("thingsync-test")
    sink.request_access()
    yield sink
    sink._store.removeCalendar_commit_error_(sink.calendar(), True, None)


@pytest.mark.live
def test_a_reminder_round_trips_through_create_scan_update_and_complete(live_sink):
    payload = ReminderPayload(
        title="live round trip",
        notes="Area › Project",
        url=marker_url("LIVE-UUID"),
        due_date=date(2026, 8, 25),
    )

    identifier = live_sink.create(payload)
    assert identifier

    # the marker is what makes the reminder findable without the state file
    assert live_sink.scan_markers() == {"LIVE-UUID": identifier}
    assert live_sink.resolve_live([identifier]) == {identifier}

    live_sink.update(identifier, ReminderPayload(
        title="renamed", notes="", url=marker_url("LIVE-UUID")
    ))
    assert live_sink._require(identifier).title() == "renamed"

    live_sink.complete(identifier)
    assert live_sink._require(identifier).isCompleted()
    # completed reminders drop out of the scan, so they are never re-adopted
    assert live_sink.scan_markers() == {}


@pytest.mark.live
def test_a_reminder_without_a_marker_is_invisible_to_the_scan(live_sink):
    import EventKit

    stranger = EventKit.EKReminder.reminderWithEventStore_(live_sink._store)
    stranger.setCalendar_(live_sink.calendar())
    stranger.setTitle_("hand made")
    live_sink._save(stranger)

    assert live_sink.scan_markers() == {}


@pytest.mark.live
def test_scanning_a_list_that_does_not_exist_does_not_create_it():
    # --dry-run scans before it decides anything, so scanning must not write.
    from thingsync.reminders_sink import RemindersSink

    sink = RemindersSink("thingsync-absent-list")
    sink.request_access()

    assert sink.scan_markers() == {}

    titles = [c.title() for c in sink._store.calendarsForEntityType_(1)]
    assert "thingsync-absent-list" not in titles
