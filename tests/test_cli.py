import pytest

from thingsync.cli import execute
from thingsync.mapping import to_payload
from thingsync.model import ThingsTodo
from thingsync.planner import ActionKind, SyncAction
from thingsync.state import State, StateEntry

PAYLOAD = to_payload(ThingsTodo(uuid="U1", title="Buy milk"))


class FakeSink:
    def __init__(self, new_id="R-NEW"):
        self.new_id = new_id
        self.calls = []

    def create(self, payload):
        self.calls.append(("create", payload.title))
        return self.new_id

    def update(self, identifier, payload):
        self.calls.append(("update", identifier))

    def complete(self, identifier):
        self.calls.append(("complete", identifier))

    def delete(self, identifier):
        self.calls.append(("delete", identifier))


def test_a_creation_records_the_new_mapping():
    state = State(target_list="Things")
    sink = FakeSink()

    execute([SyncAction(ActionKind.CREATE, "U1", payload=PAYLOAD)], sink, state, lambda s: None)

    assert sink.calls == [("create", "Buy milk")]
    assert state.items["U1"] == StateEntry("R-NEW", PAYLOAD.content_hash())


def test_state_is_persisted_after_each_action_not_once_at_the_end():
    # A crash partway through a first run must not leave created reminders
    # unrecorded, which is the mass-duplication path.
    state = State(target_list="Things")
    saves = []

    execute(
        [
            SyncAction(ActionKind.CREATE, "U1", payload=PAYLOAD),
            SyncAction(ActionKind.CREATE, "U2", payload=PAYLOAD),
        ],
        FakeSink(),
        state,
        lambda s: saves.append(set(s.items)),
    )

    assert saves == [{"U1"}, {"U1", "U2"}]


def test_completing_a_reminder_drops_its_mapping():
    state = State(target_list="Things", items={"U1": StateEntry("R1", "h")})
    sink = FakeSink()

    execute([SyncAction(ActionKind.COMPLETE, "U1", reminder_id="R1")], sink, state, lambda s: None)

    assert sink.calls == [("complete", "R1")]
    assert state.items == {}


def test_forgetting_touches_no_reminder_at_all():
    state = State(target_list="Things", items={"U1": StateEntry("R1", "h")})
    sink = FakeSink()

    execute([SyncAction(ActionKind.FORGET, "U1")], sink, state, lambda s: None)

    assert sink.calls == []
    assert state.items == {}


def test_skipping_writes_nothing():
    state = State(target_list="Things", items={"U1": StateEntry("R1", "h")})
    sink = FakeSink()

    execute([SyncAction(ActionKind.SKIP, "U1", reminder_id="R1")], sink, state, lambda s: None)

    assert sink.calls == []
    assert state.items == {"U1": StateEntry("R1", "h")}


def test_adopting_updates_in_place_and_records_the_found_identifier():
    state = State(target_list="Things")
    sink = FakeSink()

    execute(
        [SyncAction(ActionKind.ADOPT, "U1", payload=PAYLOAD, reminder_id="R7")],
        sink,
        state,
        lambda s: None,
    )

    assert sink.calls == [("update", "R7")]
    assert state.items["U1"] == StateEntry("R7", PAYLOAD.content_hash())


from thingsync.cli import DESTRUCTIVE_THRESHOLD, refusal_for_bulk_destruction


def many_completions(count):
    return [SyncAction(ActionKind.COMPLETE, f"U{i}", reminder_id=f"R{i}") for i in range(count)]


def test_a_handful_of_completions_needs_no_confirmation():
    assert refusal_for_bulk_destruction(many_completions(DESTRUCTIVE_THRESHOLD), assume_yes=False) is None


def test_wholesale_destruction_is_refused_without_yes():
    refusal = refusal_for_bulk_destruction(many_completions(DESTRUCTIVE_THRESHOLD + 1), assume_yes=False)

    assert refusal is not None and "--yes" in refusal


def test_yes_authorises_it():
    assert refusal_for_bulk_destruction(many_completions(500), assume_yes=True) is None
