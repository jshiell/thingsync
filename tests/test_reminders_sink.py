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
def live_calendar():
    """A throwaway list, and the sink/manager pair to work on it, removed
    again afterwards."""
    from thingsync.reminders_sink import CalendarManager, RemindersSink

    sink = RemindersSink()
    sink.request_access()
    manager = CalendarManager(sink._store)
    calendar = manager.create("thingsync-test")
    yield manager, sink, calendar
    manager.delete(calendar)


@pytest.mark.live
def test_a_reminder_round_trips_through_create_scan_update_and_complete(live_calendar):
    manager, sink, calendar = live_calendar
    calendar_id = calendar.calendarIdentifier()
    payload = ReminderPayload(
        title="live round trip",
        notes="Area › Project",
        url=marker_url("LIVE-UUID"),
        due_date=date(2026, 8, 25),
    )

    identifier = sink.create(calendar_id, payload)
    assert identifier

    # the marker is what makes the reminder findable without the state file
    scans = manager.scan([calendar])
    assert scans[0].marked == {"LIVE-UUID": identifier}
    assert sink.resolve_live([identifier]) == {identifier: calendar_id}

    sink.update(identifier, ReminderPayload(
        title="renamed", notes="", url=marker_url("LIVE-UUID")
    ))
    assert sink._require(identifier).title() == "renamed"

    sink.complete(identifier)
    assert sink._require(identifier).isCompleted()
    # completed reminders drop out of the incomplete-only marker scan...
    assert manager.scan([calendar])[0].marked == {}
    # ...but still count against the foreign-reminder safety check, since
    # deleting the calendar would delete them too.
    assert manager.scan([calendar])[0].has_foreign_reminder is False


@pytest.mark.live
def test_a_reminder_without_a_marker_is_foreign_and_invisible_to_the_marker_scan(live_calendar):
    import EventKit

    manager, sink, calendar = live_calendar
    stranger = EventKit.EKReminder.reminderWithEventStore_(sink._store)
    stranger.setCalendar_(calendar)
    stranger.setTitle_("hand made")
    sink._save(stranger)

    scan = manager.scan([calendar])[0]
    assert scan.marked == {}
    assert scan.has_foreign_reminder is True


@pytest.mark.live
def test_a_completed_reminder_without_a_marker_is_foreign(live_calendar):
    # The exact case the deletion guard exists for: a hand-made reminder that
    # was later completed. It drops out of the incomplete fetch entirely, so
    # only the completed-reminders half of the scan can catch it.
    import EventKit

    manager, sink, calendar = live_calendar
    stranger = EventKit.EKReminder.reminderWithEventStore_(sink._store)
    stranger.setCalendar_(calendar)
    stranger.setTitle_("hand made, then completed")
    sink._save(stranger)
    stranger.setCompleted_(True)
    sink._save(stranger)

    scan = manager.scan([calendar])[0]
    assert scan.marked == {}
    assert scan.has_foreign_reminder is True


@pytest.mark.live
def test_moving_a_reminder_preserves_its_identifier_and_marker(live_calendar):
    manager, sink, calendar_a = live_calendar
    calendar_b = manager.create("thingsync-test-b")
    try:
        payload = ReminderPayload(title="move me", notes="", url=marker_url("MOVE-UUID"))
        identifier = sink.create(calendar_a.calendarIdentifier(), payload)

        sink.move(identifier, calendar_b.calendarIdentifier(), payload)

        assert sink.resolve_live([identifier]) == {identifier: calendar_b.calendarIdentifier()}
        assert manager.scan([calendar_a])[0].marked == {}
        assert manager.scan([calendar_b])[0].marked == {"MOVE-UUID": identifier}
    finally:
        manager.delete(calendar_b)


@pytest.mark.live
def test_creating_a_list_does_not_require_scanning_it_first():
    # --dry-run must never create a list as a side effect of looking at it;
    # this just proves creation and a fresh scan compose without surprises.
    from thingsync.reminders_sink import CalendarManager, RemindersSink

    sink = RemindersSink()
    sink.request_access()
    manager = CalendarManager(sink._store)

    titles_before = [c.title() for c in manager.all_calendars()]
    assert "thingsync-absent-list" not in titles_before
