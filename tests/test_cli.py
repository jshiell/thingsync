from dataclasses import dataclass, field

import pytest

from thingsync import cli
from thingsync.cli import execute
from thingsync.mapping import FALLBACK_LIST_TITLE, to_payload
from thingsync.model import ThingsProject, ThingsTodo
from thingsync.planner import ActionKind, SyncAction
from thingsync.state import State, StateEntry

PAYLOAD = to_payload(ThingsTodo(uuid="U1", title="Buy milk"))


class FakeSink:
    def __init__(self, live=None):
        self.live = dict(live or {})  # reminder_id -> calendar_id
        self.calls = []
        self._next_id = 0

    def resolve_live(self, identifiers):
        wanted = set(identifiers)
        return {rid: cal for rid, cal in self.live.items() if rid in wanted}

    def create(self, calendar_id, payload):
        self._next_id += 1
        identifier = f"R-NEW-{self._next_id}"
        self.calls.append(("create", calendar_id, payload.title))
        return identifier

    def update(self, identifier, payload):
        self.calls.append(("update", identifier))

    def move(self, identifier, calendar_id, payload):
        self.calls.append(("move", identifier, calendar_id))

    def complete(self, identifier):
        self.calls.append(("complete", identifier))

    def delete(self, identifier):
        self.calls.append(("delete", identifier))


def test_a_creation_records_the_new_mapping():
    states = {None: State(target_list="Things")}
    keys = {"U1": None}
    sink = FakeSink()

    execute(
        [SyncAction(ActionKind.CREATE, "U1", payload=PAYLOAD, calendar_id="CAL")],
        sink, states, keys, lambda k, s: None,
    )

    assert sink.calls == [("create", "CAL", "Buy milk")]
    assert states[None].items["U1"] == StateEntry("R-NEW-1", PAYLOAD.content_hash())


def test_state_is_persisted_after_each_action_not_once_at_the_end():
    states = {None: State(target_list="Things")}
    keys = {"U1": None, "U2": None}
    saves = []

    execute(
        [
            SyncAction(ActionKind.CREATE, "U1", payload=PAYLOAD, calendar_id="CAL"),
            SyncAction(ActionKind.CREATE, "U2", payload=PAYLOAD, calendar_id="CAL"),
        ],
        FakeSink(), states, keys, lambda k, s: saves.append(set(s.items)),
    )

    assert saves == [{"U1"}, {"U1", "U2"}]


def test_completing_a_reminder_drops_its_mapping():
    states = {"P1": State(target_list="Website", items={"U1": StateEntry("R1", "h")})}
    keys = {"U1": "P1"}
    sink = FakeSink()

    execute([SyncAction(ActionKind.COMPLETE, "U1", reminder_id="R1")], sink, states, keys, lambda k, s: None)

    assert sink.calls == [("complete", "R1")]
    assert states["P1"].items == {}


def test_forgetting_touches_no_reminder_at_all():
    states = {"P1": State(target_list="Website", items={"U1": StateEntry("R1", "h")})}
    keys = {"U1": "P1"}
    sink = FakeSink()

    execute([SyncAction(ActionKind.FORGET, "U1")], sink, states, keys, lambda k, s: None)

    assert sink.calls == []
    assert states["P1"].items == {}


def test_skipping_writes_nothing():
    states = {"P1": State(target_list="Website", items={"U1": StateEntry("R1", "h")})}
    keys = {"U1": "P1"}
    sink = FakeSink()

    execute([SyncAction(ActionKind.SKIP, "U1", reminder_id="R1")], sink, states, keys, lambda k, s: None)

    assert sink.calls == []
    assert states["P1"].items == {"U1": StateEntry("R1", "h")}


def test_adopting_updates_in_place_and_records_the_found_identifier():
    states = {"P1": State(target_list="Website")}
    keys = {"U1": "P1"}
    sink = FakeSink()

    execute(
        [SyncAction(ActionKind.ADOPT, "U1", payload=PAYLOAD, reminder_id="R7", calendar_id="CAL")],
        sink, states, keys, lambda k, s: None,
    )

    assert sink.calls == [("update", "R7")]
    assert states["P1"].items["U1"] == StateEntry("R7", PAYLOAD.content_hash())


def test_a_move_relocates_the_reminder_and_records_it_under_the_new_project():
    states = {"A": State(target_list="A", items={"U1": StateEntry("R1", "old")}), "B": State(target_list="B")}
    keys = {"U1": "B"}  # the to-do's *current* project, per cli's key resolution
    sink = FakeSink()

    execute(
        [SyncAction(ActionKind.MOVE, "U1", payload=PAYLOAD, reminder_id="R1", calendar_id="CAL-B")],
        sink, states, keys, lambda k, s: None,
    )

    assert sink.calls == [("move", "R1", "CAL-B")]
    assert states["B"].items["U1"] == StateEntry("R1", PAYLOAD.content_hash())
    assert "U1" not in states["A"].items


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


# --- sync_command integration, via fakes for CalendarManager and RemindersSink ---

import argparse


@dataclass
class FakeScan:
    calendar_id: str
    title: str
    marked: dict = field(default_factory=dict)
    has_foreign_reminder: bool = False


class FakeCalendar:
    def __init__(self, calendar_id, title):
        self.calendar_id = calendar_id
        self._title = title

    def calendarIdentifier(self):
        return self.calendar_id

    def title(self):
        return self._title

    def setTitle_(self, title):
        self._title = title


class FakeManager:
    def __init__(self, calendars=(), scans=None):
        self.calendars = list(calendars)
        self._scans = {s.calendar_id: s for s in (scans or [])}
        self.created = []
        self.renamed = []
        self.deleted = []
        self._next_id = 0

    def all_calendars(self):
        return list(self.calendars)

    def create(self, title):
        self._next_id += 1
        calendar = FakeCalendar(f"NEW-{self._next_id}", title)
        self.calendars.append(calendar)
        self._scans[calendar.calendar_id] = FakeScan(calendar.calendar_id, title)
        self.created.append(title)
        return calendar

    def rename(self, calendar, title):
        calendar.setTitle_(title)
        self.renamed.append((calendar.calendarIdentifier(), title))

    def delete(self, calendar):
        self.calendars = [c for c in self.calendars if c.calendarIdentifier() != calendar.calendarIdentifier()]
        self.deleted.append(calendar.calendarIdentifier())

    def scan(self, calendars):
        return [
            self._scans.get(c.calendarIdentifier(), FakeScan(c.calendarIdentifier(), c.title()))
            for c in calendars
        ]


def sync_args(project=None, dry_run=False, on_done="complete", yes=False):
    return argparse.Namespace(project=project, dry_run=dry_run, on_done=on_done, yes=yes)


def fallback_calendar():
    return FakeCalendar("INBOX", FALLBACK_LIST_TITLE)


def test_a_brand_new_project_gets_a_list_and_its_todo_is_created(monkeypatch, tmp_path):
    monkeypatch.setenv("THINGSYNC_STATE_DIR", str(tmp_path))
    manager = FakeManager(calendars=[fallback_calendar()])
    sink = FakeSink()
    monkeypatch.setattr(cli, "_open_reminders", lambda: (sink, manager))

    code = cli.sync_command(
        sync_args(),
        load_todos=lambda: [ThingsTodo(uuid="U1", title="Buy tiles", project_uuid="P1")],
        load_projects=lambda: [ThingsProject(uuid="P1", title="Website", status="incomplete")],
    )

    assert code == 0
    assert manager.created == ["Website"]
    assert ("create", "NEW-1", "Buy tiles") in sink.calls


def test_dry_run_writes_no_reminders_and_creates_no_lists(monkeypatch, tmp_path):
    monkeypatch.setenv("THINGSYNC_STATE_DIR", str(tmp_path))
    manager = FakeManager(calendars=[fallback_calendar()])
    sink = FakeSink()
    monkeypatch.setattr(cli, "_open_reminders", lambda: (sink, manager))

    code = cli.sync_command(
        sync_args(dry_run=True),
        load_todos=lambda: [ThingsTodo(uuid="U1", title="Buy tiles", project_uuid="P1")],
        load_projects=lambda: [ThingsProject(uuid="P1", title="Website", status="incomplete")],
    )

    assert code == 0
    assert manager.created == []
    assert sink.calls == []
    from thingsync.state import project_state_path

    assert not project_state_path("P1").exists()


def test_bulk_destruction_refusal_stops_before_any_sink_write(monkeypatch, tmp_path):
    from thingsync.registry import Registry, RegistryEntry, save as save_registry, registry_path
    from thingsync.state import project_state_path, save as save_state

    monkeypatch.setenv("THINGSYNC_STATE_DIR", str(tmp_path))

    gone = {f"U{i}": StateEntry(reminder_id=f"R{i}", hash="h") for i in range(DESTRUCTIVE_THRESHOLD + 1)}
    save_state(project_state_path("P1"), State(target_list="Website", items=gone, project_uuid="P1"))
    save_registry(registry_path(), Registry(projects={"P1": RegistryEntry("CAL-P1", "Website")}))

    calendar = FakeCalendar("CAL-P1", "Website")
    manager = FakeManager(calendars=[calendar, fallback_calendar()])
    sink = FakeSink(live={rid: "CAL-P1" for rid in (e.reminder_id for e in gone.values())})
    monkeypatch.setattr(cli, "_open_reminders", lambda: (sink, manager))

    code = cli.sync_command(
        sync_args(),
        load_todos=lambda: [],
        load_projects=lambda: [ThingsProject(uuid="P1", title="Website", status="completed")],
    )

    assert code == 1
    assert sink.calls == []


def test_project_scoping_selects_only_the_named_project(monkeypatch, tmp_path):
    monkeypatch.setenv("THINGSYNC_STATE_DIR", str(tmp_path))
    manager = FakeManager(calendars=[fallback_calendar()])
    sink = FakeSink()
    monkeypatch.setattr(cli, "_open_reminders", lambda: (sink, manager))

    code = cli.sync_command(
        sync_args(project="Website"),
        load_todos=lambda: [
            ThingsTodo(uuid="U1", title="Buy tiles", project_uuid="P1"),
            ThingsTodo(uuid="U2", title="Book flight", project_uuid="P2"),
        ],
        load_projects=lambda: [
            ThingsProject(uuid="P1", title="Website", status="incomplete"),
            ThingsProject(uuid="P2", title="Travel", status="incomplete"),
        ],
    )

    assert code == 0
    assert manager.created == ["Website"]
    titles_created_for = [call[2] for call in sink.calls if call[0] == "create"]
    assert titles_created_for == ["Buy tiles"]


def test_an_unknown_project_name_is_a_hard_error(monkeypatch, tmp_path, capsys):
    monkeypatch.setenv("THINGSYNC_STATE_DIR", str(tmp_path))
    manager = FakeManager(calendars=[fallback_calendar()])
    sink = FakeSink()
    monkeypatch.setattr(cli, "_open_reminders", lambda: (sink, manager))

    code = cli.sync_command(
        sync_args(project="Nonexistent"),
        load_todos=lambda: [],
        load_projects=lambda: [ThingsProject(uuid="P1", title="Website", status="incomplete")],
    )

    assert code == 1
    assert "Nonexistent" in capsys.readouterr().err
    assert manager.created == []


def test_an_ambiguous_project_name_is_a_hard_error_not_a_first_match(monkeypatch, tmp_path, capsys):
    monkeypatch.setenv("THINGSYNC_STATE_DIR", str(tmp_path))
    manager = FakeManager(calendars=[fallback_calendar()])
    sink = FakeSink()
    monkeypatch.setattr(cli, "_open_reminders", lambda: (sink, manager))

    code = cli.sync_command(
        sync_args(project="Errands"),
        load_todos=lambda: [],
        load_projects=lambda: [
            ThingsProject(uuid="P1", title="Errands", status="incomplete"),
            ThingsProject(uuid="P2", title="Errands", status="incomplete"),
        ],
    )

    assert code == 1
    error = capsys.readouterr().err
    assert "Errands" in error and "ambiguous" not in error.lower() or "matches" in error
    assert manager.created == []


def test_a_list_deletion_is_refused_and_reported_without_yes(monkeypatch, tmp_path, capsys):
    from thingsync.registry import Registry, RegistryEntry, save as save_registry, registry_path

    monkeypatch.setenv("THINGSYNC_STATE_DIR", str(tmp_path))
    save_registry(registry_path(), Registry(projects={"P1": RegistryEntry("CAL-P1", "Website")}))

    calendar = FakeCalendar("CAL-P1", "Website")
    manager = FakeManager(calendars=[calendar, fallback_calendar()])
    sink = FakeSink()
    monkeypatch.setattr(cli, "_open_reminders", lambda: (sink, manager))

    code = cli.sync_command(
        sync_args(),
        load_todos=lambda: [],
        load_projects=lambda: [ThingsProject(uuid="P1", title="Website", status="completed")],
    )

    assert code == 0
    assert manager.deleted == []
    assert "--yes" in capsys.readouterr().out


def test_a_confirmed_list_deletion_removes_the_list_and_its_state(monkeypatch, tmp_path):
    from thingsync.registry import Registry, RegistryEntry, load as load_registry, save as save_registry, registry_path
    from thingsync.state import project_state_path, save as save_state

    monkeypatch.setenv("THINGSYNC_STATE_DIR", str(tmp_path))
    save_registry(registry_path(), Registry(projects={"P1": RegistryEntry("CAL-P1", "Website")}))
    save_state(project_state_path("P1"), State(target_list="Website", items={}, project_uuid="P1"))

    calendar = FakeCalendar("CAL-P1", "Website")
    manager = FakeManager(calendars=[calendar, fallback_calendar()])
    sink = FakeSink()
    monkeypatch.setattr(cli, "_open_reminders", lambda: (sink, manager))

    code = cli.sync_command(
        sync_args(yes=True),
        load_todos=lambda: [],
        load_projects=lambda: [ThingsProject(uuid="P1", title="Website", status="completed")],
    )

    assert code == 0
    assert manager.deleted == ["CAL-P1"]
    assert not project_state_path("P1").exists()
    assert "P1" not in load_registry(registry_path()).projects


def test_sync_hard_errors_on_legacy_state_before_touching_things_or_reminders(
    monkeypatch, tmp_path, capsys
):
    # A file left from a *different* list than the one this run targets: it
    # must still be caught, and must be caught before Things or Reminders is
    # even opened.
    monkeypatch.setenv("THINGSYNC_STATE_DIR", str(tmp_path))
    (tmp_path / "Scratch.json").write_text(
        '{"version": 1, "target_list": "Scratch", "items": {}}', encoding="utf-8"
    )

    from thingsync import things_source

    def boom():
        raise AssertionError("Things must not be read once legacy state is found")

    def sink_boom():
        raise AssertionError("Reminders must not be opened once legacy state is found")

    monkeypatch.setattr(cli, "_open_reminders", sink_boom)
    monkeypatch.setattr(things_source, "load_todos", boom)
    monkeypatch.setattr(things_source, "load_projects", boom)

    code = cli.main(["sync"])

    assert code == 1
    error = capsys.readouterr().err
    assert "Scratch.json" in error
    assert "migrate" in error.lower()


def test_main_reports_a_denied_reminders_grant_without_a_traceback(monkeypatch, tmp_path, capsys):
    from thingsync import things_source
    from thingsync.reminders_sink import RemindersError

    monkeypatch.setenv("THINGSYNC_STATE_DIR", str(tmp_path))

    def boom():
        raise RemindersError("Reminders access was not granted; run `thingsync doctor`")

    monkeypatch.setattr(cli, "_open_reminders", boom)
    monkeypatch.setattr(things_source, "load_todos", lambda: [])
    monkeypatch.setattr(things_source, "load_projects", lambda: [])

    code = cli.main(["sync"])

    assert code == 1
    assert "thingsync doctor" in capsys.readouterr().err


@pytest.mark.parametrize("argv", [["rebuild-state"]])
def test_rebuild_state_also_reports_a_denied_grant_without_a_traceback(monkeypatch, tmp_path, capsys, argv):
    from thingsync import things_source
    from thingsync.reminders_sink import RemindersError

    monkeypatch.setenv("THINGSYNC_STATE_DIR", str(tmp_path))

    def boom():
        raise RemindersError("Reminders access was not granted; run `thingsync doctor`")

    monkeypatch.setattr(cli, "_open_reminders", boom)
    monkeypatch.setattr(things_source, "load_projects", lambda: [])

    code = cli.main(argv)

    assert code == 1
    assert "thingsync doctor" in capsys.readouterr().err


# --- rebuild-state: project-aware recovery from calendar contents ---

from thingsync.registry import RegistryEntry, load as load_registry, registry_path


def marker_scan(calendar_id, title, marked):
    return FakeScan(calendar_id, title, dict(marked))


def test_a_projects_markers_recover_its_state_and_registry_entry(monkeypatch, tmp_path):
    monkeypatch.setenv("THINGSYNC_STATE_DIR", str(tmp_path))
    website = FakeCalendar("CAL-P1", "Website")
    manager = FakeManager(
        calendars=[website, fallback_calendar()],
        scans=[marker_scan("CAL-P1", "Website", {"U1": "R1"}), marker_scan("INBOX", FALLBACK_LIST_TITLE, {})],
    )
    sink = FakeSink()
    monkeypatch.setattr(cli, "_open_reminders", lambda: (sink, manager))

    code = cli.rebuild_state_command(
        argparse.Namespace(),
        load_todos=lambda: [ThingsTodo(uuid="U1", title="Buy tiles", project_uuid="P1")],
        load_projects=lambda: [ThingsProject(uuid="P1", title="Website", status="incomplete")],
    )

    assert code == 0
    from thingsync.state import load as load_state, project_state_path

    recovered = load_state(project_state_path("P1"), target_list="Website", project_uuid="P1")
    assert recovered.items == {"U1": StateEntry("R1", "")}
    assert load_registry(registry_path()).projects["P1"] == RegistryEntry("CAL-P1", "Website")


def test_an_orphan_marker_is_reported_and_excluded(monkeypatch, tmp_path, capsys):
    monkeypatch.setenv("THINGSYNC_STATE_DIR", str(tmp_path))
    website = FakeCalendar("CAL-P1", "Website")
    manager = FakeManager(
        calendars=[website, fallback_calendar()],
        scans=[
            marker_scan("CAL-P1", "Website", {"U1": "R1", "GONE": "R9"}),
            marker_scan("INBOX", FALLBACK_LIST_TITLE, {}),
        ],
    )
    sink = FakeSink()
    monkeypatch.setattr(cli, "_open_reminders", lambda: (sink, manager))

    code = cli.rebuild_state_command(
        argparse.Namespace(),
        load_todos=lambda: [ThingsTodo(uuid="U1", title="Buy tiles", project_uuid="P1")],
        load_projects=lambda: [ThingsProject(uuid="P1", title="Website", status="incomplete")],
    )

    assert code == 0
    from thingsync.state import load as load_state, project_state_path

    recovered = load_state(project_state_path("P1"), target_list="Website", project_uuid="P1")
    assert recovered.items == {"U1": StateEntry("R1", "")}
    assert "GONE" in capsys.readouterr().out


def test_an_empty_unattributable_list_is_reported_not_silently_dropped(monkeypatch, tmp_path, capsys):
    monkeypatch.setenv("THINGSYNC_STATE_DIR", str(tmp_path))
    mystery = FakeCalendar("CAL-X", "Mystery List")
    manager = FakeManager(
        calendars=[mystery, fallback_calendar()],
        scans=[marker_scan("CAL-X", "Mystery List", {}), marker_scan("INBOX", FALLBACK_LIST_TITLE, {})],
    )
    sink = FakeSink()
    monkeypatch.setattr(cli, "_open_reminders", lambda: (sink, manager))

    code = cli.rebuild_state_command(
        argparse.Namespace(),
        load_todos=lambda: [],
        load_projects=lambda: [ThingsProject(uuid="P1", title="Website", status="incomplete")],
    )

    assert code == 0
    assert "Mystery List" in capsys.readouterr().out
    assert "P1" not in load_registry(registry_path()).projects


def test_a_projects_markers_split_across_two_lists_is_reported_not_silently_picked(monkeypatch, tmp_path, capsys):
    monkeypatch.setenv("THINGSYNC_STATE_DIR", str(tmp_path))
    first = FakeCalendar("CAL-1", "Website")
    second = FakeCalendar("CAL-2", "Website Copy")
    manager = FakeManager(
        calendars=[first, second, fallback_calendar()],
        scans=[
            marker_scan("CAL-1", "Website", {"U1": "R1"}),
            marker_scan("CAL-2", "Website Copy", {"U2": "R2"}),
            marker_scan("INBOX", FALLBACK_LIST_TITLE, {}),
        ],
    )
    sink = FakeSink()
    monkeypatch.setattr(cli, "_open_reminders", lambda: (sink, manager))

    code = cli.rebuild_state_command(
        argparse.Namespace(),
        load_todos=lambda: [
            ThingsTodo(uuid="U1", title="a", project_uuid="P1"),
            ThingsTodo(uuid="U2", title="b", project_uuid="P1"),
        ],
        load_projects=lambda: [ThingsProject(uuid="P1", title="Website", status="incomplete")],
    )

    assert code == 0
    output = capsys.readouterr().out
    assert "Website" in output and "Website Copy" in output
    assert "P1" not in load_registry(registry_path()).projects
    from thingsync.state import project_state_path

    assert not project_state_path("P1").exists()


def test_markers_for_todos_with_no_project_recover_into_the_inbox(monkeypatch, tmp_path):
    monkeypatch.setenv("THINGSYNC_STATE_DIR", str(tmp_path))
    manager = FakeManager(
        calendars=[fallback_calendar()],
        scans=[marker_scan("INBOX", FALLBACK_LIST_TITLE, {"U1": "R1"})],
    )
    sink = FakeSink()
    monkeypatch.setattr(cli, "_open_reminders", lambda: (sink, manager))

    code = cli.rebuild_state_command(
        argparse.Namespace(),
        load_todos=lambda: [ThingsTodo(uuid="U1", title="Buy milk")],
        load_projects=lambda: [],
    )

    assert code == 0
    from thingsync.state import load as load_state, inbox_state_path

    recovered = load_state(inbox_state_path(), target_list=FALLBACK_LIST_TITLE, project_uuid=None)
    assert recovered.items == {"U1": StateEntry("R1", "")}
