import pytest

from thingsync.protocols import ReminderSink


class FakeReminderSink:
    def resolve_live(self, identifiers):
        return {}

    def create(self, calendar_id, payload):
        return "R1"

    def update(self, identifier, payload):
        pass

    def move(self, identifier, calendar_id, payload):
        pass

    def complete(self, identifier):
        pass

    def delete(self, identifier):
        pass


def test_fake_sink_satisfies_reminder_sink():
    assert issubclass(FakeReminderSink, ReminderSink)


def test_reminders_sink_satisfies_reminder_sink():
    pytest.importorskip("EventKit")
    from thingsync.reminders_sink import RemindersSink

    assert issubclass(RemindersSink, ReminderSink)
