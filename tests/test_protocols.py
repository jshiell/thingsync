import pytest

from thingsync.protocols import ReminderSink


class FakeReminderSink:
    def scan_markers(self):
        return {}

    def resolve_live(self, identifiers):
        return set()

    def create(self, payload):
        return "R1"

    def update(self, identifier, payload):
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
