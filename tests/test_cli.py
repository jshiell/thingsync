import pytest

from thingsync import cli
from thingsync.cli import execute
from thingsync.mapping import to_payload
from thingsync.model import ThingsTodo
from thingsync.planner import ActionKind, SyncAction
from thingsync.state import State, StateEntry

PAYLOAD = to_payload(ThingsTodo(uuid="U1", title="Buy milk"))


class FakeSink:
    def __init__(self, new_id="R-NEW", markers=None, live_ids=None):
        self.new_id = new_id
        self.markers = markers or {}
        self.live_ids = live_ids or set()
        self.calls = []

    def scan_markers(self):
        return self.markers

    def resolve_live(self, identifiers):
        return {identifier for identifier in identifiers if identifier in self.live_ids}

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


import argparse

from thingsync import state as state_module
from thingsync import things_source


def sync_args(target_list="Things", dry_run=False, on_done="complete", yes=False):
    return argparse.Namespace(
        target_list=target_list, dry_run=dry_run, on_done=on_done, yes=yes
    )


def test_dry_run_writes_no_reminders_and_no_state_file(monkeypatch, tmp_path):
    state_file = tmp_path / "Things.json"
    monkeypatch.setattr(state_module, "state_path", lambda target_list: state_file)
    monkeypatch.setattr(things_source, "load_todos", lambda: [ThingsTodo(uuid="U1", title="Buy milk")])
    sink = FakeSink()
    monkeypatch.setattr(cli, "_open_sink", lambda target_list: sink)

    code = cli.sync_command(sync_args(dry_run=True))

    assert code == 0
    assert sink.calls == []
    assert not state_file.exists()


def test_bulk_destruction_refusal_stops_before_any_sink_write(monkeypatch, tmp_path):
    state_file = tmp_path / "Things.json"
    gone = {
        f"U{i}": StateEntry(reminder_id=f"R{i}", hash="h")
        for i in range(DESTRUCTIVE_THRESHOLD + 1)
    }
    from thingsync.state import save

    save(state_file, State(target_list="Things", items=gone))

    monkeypatch.setattr(state_module, "state_path", lambda target_list: state_file)
    monkeypatch.setattr(things_source, "load_todos", lambda: [])
    sink = FakeSink(live_ids=set(gone[uuid].reminder_id for uuid in gone))
    monkeypatch.setattr(cli, "_open_sink", lambda target_list: sink)

    code = cli.sync_command(sync_args())

    assert code == 1
    assert sink.calls == []


def test_main_reports_a_denied_reminders_grant_without_a_traceback(monkeypatch, capsys):
    from thingsync.reminders_sink import RemindersError

    def boom(args):
        raise RemindersError("Reminders access was not granted; run `thingsync doctor`")

    monkeypatch.setattr(cli, "sync_command", boom)

    code = cli.main(["sync"])

    assert code == 1
    assert "thingsync doctor" in capsys.readouterr().err
