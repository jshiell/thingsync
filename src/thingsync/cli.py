"""Command line entry point."""

from __future__ import annotations

import argparse
import sys
from collections import Counter
from collections.abc import Callable, Iterable, Mapping

from thingsync.mapping import FALLBACK_LIST_TITLE, list_title_for_project
from thingsync.model import ThingsProject, ThingsTodo
from thingsync.planner import ActionKind, SyncAction, destructive_actions
from thingsync.projects_planner import CalendarInfo, ListAction, ListActionKind, plan_lists
from thingsync.protocols import ReminderSink
from thingsync.registry import RegistryEntry
from thingsync.state import State, StateEntry

DESTRUCTIVE_THRESHOLD = 10


def refusal_for_bulk_destruction(
    actions: Iterable[SyncAction], assume_yes: bool
) -> str | None:
    """Refuse to clear reminders wholesale unless explicitly authorised.

    A planner bug or a half-read database should not be able to silently
    empty someone's reminders. List deletion has its own, separate gate: it
    always needs ``--yes``, regardless of how many lists are involved.
    """
    if assume_yes:
        return None

    destructive = destructive_actions(actions)
    if len(destructive) <= DESTRUCTIVE_THRESHOLD:
        return None

    return (
        f"{len(destructive)} reminders would be completed or deleted, which is "
        f"more than the {DESTRUCTIVE_THRESHOLD} allowed without confirmation. "
        "Re-run with --dry-run to inspect the plan, or --yes to go ahead."
    )


def execute(
    actions: Iterable[SyncAction],
    sink: ReminderSink,
    states: Mapping[str | None, State],
    state_key_for_uuid: Mapping[str, str | None],
    persist: Callable[[str | None, State], None],
) -> Counter:
    """Carry out the reminder-level plan, recording each success before moving on.

    Every project's (and the fallback's) state is persisted after every
    action rather than once at the end: a crash partway through must not
    leave created or moved reminders unrecorded.
    """
    tally: Counter = Counter()

    for action in actions:
        key = state_key_for_uuid[action.uuid]
        state = states[key]

        if action.kind is ActionKind.CREATE:
            identifier = sink.create(action.calendar_id, action.payload)
            state.items[action.uuid] = StateEntry(identifier, action.payload.content_hash())
        elif action.kind is ActionKind.MOVE:
            # Drop any stale record of this to-do under its old project first:
            # a crash here just means the next run's marker scan finds the
            # reminder still sitting in its old calendar and retries the move,
            # never a duplicate.
            for other_key, other_state in states.items():
                if other_key != key and other_state.items.pop(action.uuid, None) is not None:
                    persist(other_key, other_state)
            sink.move(action.reminder_id, action.calendar_id, action.payload)
            state.items[action.uuid] = StateEntry(action.reminder_id, action.payload.content_hash())
        elif action.kind in (ActionKind.ADOPT, ActionKind.UPDATE):
            sink.update(action.reminder_id, action.payload)
            state.items[action.uuid] = StateEntry(action.reminder_id, action.payload.content_hash())
        elif action.kind is ActionKind.COMPLETE:
            sink.complete(action.reminder_id)
            state.items.pop(action.uuid, None)
        elif action.kind is ActionKind.DELETE:
            sink.delete(action.reminder_id)
            state.items.pop(action.uuid, None)
        elif action.kind is ActionKind.FORGET:
            state.items.pop(action.uuid, None)
        else:
            tally[action.kind.value] += 1
            continue

        tally[action.kind.value] += 1
        persist(key, state)

    return tally


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="thingsync",
        description="One-way mirror from Things 3 to Apple Reminders.",
    )
    commands = parser.add_subparsers(dest="command", required=True)

    commands.add_parser("doctor", help="check the permissions thingsync needs")

    sync = commands.add_parser(
        "sync", help="mirror open Things to-dos into one Reminders list per project"
    )
    sync.add_argument(
        "--project", dest="project", default=None,
        help="restrict this run to one project's list, by title",
    )
    sync.add_argument("--dry-run", action="store_true",
                      help="print the plan and write nothing")
    sync.add_argument("--on-done", choices=("complete", "delete"), default="complete",
                      help="what to do with reminders whose to-do is no longer open")
    sync.add_argument("--yes", action="store_true",
                      help="authorise bulk completion/deletion of reminders, or any list deletion")

    commands.add_parser(
        "rebuild-state",
        help="reconstruct state by scanning every thingsync Reminders list for markers",
    )

    return parser


def describe(action: SyncAction) -> str:
    title = action.payload.title if action.payload else action.uuid
    return f"{action.kind.value:>8}  {title}"


def describe_list_action(action: ListAction) -> str:
    if action.reason:
        return f"  refused  {action.title!r}: {action.reason}"
    return f"{action.kind.value:>12}  {action.title!r}"


def _open_reminders():
    from thingsync.reminders_sink import CalendarManager, RemindersSink

    sink = RemindersSink()
    sink.request_access()
    return sink, CalendarManager(sink._store)


def _select_project(projects: list[ThingsProject], name: str) -> ThingsProject | str:
    """The one project named ``name``, or an error message."""
    matches = [p for p in projects if p.title == name and p.status == "incomplete"]
    if not matches:
        return f"no open project named {name!r}"
    if len(matches) > 1:
        return f"{name!r} matches {len(matches)} projects; --project cannot disambiguate duplicate titles"
    return matches[0]


def _calendar_infos(existing_calendars, scans, todo_by_uuid: Mapping[str, ThingsTodo]) -> list[CalendarInfo]:
    infos = []
    for calendar, scan in zip(existing_calendars, scans):
        attested = {
            todo_by_uuid[uuid].project_uuid
            for uuid in scan.marked
            if uuid in todo_by_uuid and todo_by_uuid[uuid].project_uuid is not None
        }
        infos.append(CalendarInfo(scan.calendar_id, scan.title, frozenset(attested), scan.has_foreign_reminder))
    return infos


def sync_command(
    args,
    load_todos: Callable[[], list[ThingsTodo]] | None = None,
    load_projects: Callable[[], list[ThingsProject]] | None = None,
) -> int:
    from thingsync.planner import plan
    from thingsync.registry import load as load_registry, registry_path, save as save_registry
    from thingsync.state import (
        check_for_legacy_state,
        inbox_state_path,
        load as load_state,
        project_state_path,
        save as save_state,
    )

    check_for_legacy_state()

    if load_todos is None:
        from thingsync.things_source import load_todos
    if load_projects is None:
        from thingsync.things_source import load_projects

    todos = load_todos()
    projects = load_projects()
    todo_by_uuid = {todo.uuid: todo for todo in todos}
    project_by_uuid = {project.uuid: project for project in projects}

    selected_project: ThingsProject | None = None
    if args.project is not None:
        selected = _select_project(projects, args.project)
        if isinstance(selected, str):
            print(f"Refusing: {selected}", file=sys.stderr)
            return 1
        selected_project = selected

    sink, manager = _open_reminders()

    existing_calendars = manager.all_calendars()
    scans = manager.scan(existing_calendars)
    raw_calendar_by_id = {calendar.calendarIdentifier(): calendar for calendar in existing_calendars}
    calendar_infos = _calendar_infos(existing_calendars, scans, todo_by_uuid)

    reg_path = registry_path()
    registry = load_registry(reg_path)

    list_actions = plan_lists(projects, registry, calendar_infos)

    calendar_for_project: dict[str | None, str] = {}
    executed_list_actions: list[ListAction] = []

    for action in list_actions:
        execute_this_one = selected_project is None or action.project_uuid == selected_project.uuid

        if action.kind is ListActionKind.CREATE_LIST:
            if not execute_this_one:
                calendar_for_project[action.project_uuid] = f"__pending__:{action.project_uuid}"
            elif args.dry_run:
                calendar_for_project[action.project_uuid] = f"(new list) {action.title}"
            else:
                calendar = manager.create(action.title)
                calendar_id = calendar.calendarIdentifier()
                raw_calendar_by_id[calendar_id] = calendar
                calendar_for_project[action.project_uuid] = calendar_id
                registry.projects[action.project_uuid] = RegistryEntry(calendar_id, action.title)
                save_registry(reg_path, registry)
        elif action.kind is ListActionKind.RENAME_LIST:
            calendar_for_project[action.project_uuid] = action.calendar_id
            if execute_this_one and not args.dry_run:
                manager.rename(raw_calendar_by_id[action.calendar_id], action.title)
                registry.projects[action.project_uuid] = RegistryEntry(action.calendar_id, action.title)
                save_registry(reg_path, registry)
        elif action.kind is ListActionKind.ADOPT_LIST:
            calendar_for_project[action.project_uuid] = action.calendar_id
            if execute_this_one and not args.dry_run:
                calendar = raw_calendar_by_id[action.calendar_id]
                if calendar.title() != action.title:
                    manager.rename(calendar, action.title)
                registry.projects[action.project_uuid] = RegistryEntry(action.calendar_id, action.title)
                save_registry(reg_path, registry)
        elif action.kind is ListActionKind.KEEP and action.reason is None:
            calendar_for_project[action.project_uuid] = action.calendar_id

        if execute_this_one:
            executed_list_actions.append(action)
            print(describe_list_action(action))

    fallback_calendar = next((c for c in existing_calendars if c.title() == FALLBACK_LIST_TITLE), None)
    if fallback_calendar is not None:
        calendar_for_project[None] = fallback_calendar.calendarIdentifier()
    elif args.dry_run:
        calendar_for_project[None] = f"(new list) {FALLBACK_LIST_TITLE}"
    else:
        fallback_calendar = manager.create(FALLBACK_LIST_TITLE)
        calendar_for_project[None] = fallback_calendar.calendarIdentifier()
        raw_calendar_by_id[fallback_calendar.calendarIdentifier()] = fallback_calendar

    # A todo/project race between the two Things reads (each its own
    # transaction, see plan.md) could leave a todo pointing at a project this
    # run never planned a list for. Route it to the fallback rather than
    # crashing the whole sync over a to-do that will resolve itself next run.
    for todo in todos:
        calendar_for_project.setdefault(todo.project_uuid, calendar_for_project[None])

    project_uuids_to_load = {p.uuid for p in projects if p.status == "incomplete"} | set(registry.projects.keys())

    states: dict[str | None, State] = {}
    state_key_for_uuid: dict[str, str | None] = {}

    for uuid in project_uuids_to_load:
        entry = registry.projects.get(uuid)
        project = project_by_uuid.get(uuid)
        title = list_title_for_project(project) if project else (entry.title if entry else uuid)
        state = load_state(project_state_path(uuid), target_list=title, project_uuid=uuid)
        states[uuid] = state
        for todo_uuid in state.items:
            state_key_for_uuid[todo_uuid] = uuid

    inbox_state = load_state(inbox_state_path(), target_list=FALLBACK_LIST_TITLE, project_uuid=None)
    states[None] = inbox_state
    for todo_uuid in inbox_state.items:
        state_key_for_uuid[todo_uuid] = None

    for todo in todos:
        state_key_for_uuid[todo.uuid] = todo.project_uuid

    items = {}
    for state in states.values():
        items.update(state.items)

    markers = {uuid: (scan.calendar_id, rid) for scan in scans for uuid, rid in scan.marked.items()}
    all_reminder_ids = {entry.reminder_id for state in states.values() for entry in state.items.values()}
    live = sink.resolve_live(all_reminder_ids)

    reminder_actions = plan(todos, items, markers, live, calendar_for_project, on_done=args.on_done)

    if selected_project is not None:
        target_calendar_id = calendar_for_project[selected_project.uuid]
        reminder_actions = [
            action for action in reminder_actions
            if (action.calendar_id == target_calendar_id if action.calendar_id is not None
                else state_key_for_uuid.get(action.uuid) == selected_project.uuid)
        ]

    interesting = [a for a in reminder_actions if a.kind is not ActionKind.SKIP]
    for action in interesting:
        print(describe(action))
    skipped = len(reminder_actions) - len(interesting)

    deletions = [a for a in executed_list_actions if a.kind is ListActionKind.DELETE_LIST]
    confirmed_deletions = deletions if args.yes else []
    if deletions and not args.yes:
        for action in deletions:
            print(f"  refused  {action.title!r}: list deletion always needs --yes")

    if args.dry_run:
        print(f"\n{len(interesting)} actions, {skipped} unchanged. Nothing written (--dry-run).")
        return 0

    refusal = refusal_for_bulk_destruction(reminder_actions, assume_yes=args.yes)
    if refusal:
        print(f"\nRefusing: {refusal}", file=sys.stderr)
        return 1

    tally = execute(
        reminder_actions, sink, states, state_key_for_uuid,
        lambda key, state: save_state(project_state_path(key) if key is not None else inbox_state_path(), state),
    )

    for action in confirmed_deletions:
        calendar = raw_calendar_by_id[action.calendar_id]
        manager.delete(calendar)
        project_state_path(action.project_uuid).unlink(missing_ok=True)
        registry.projects.pop(action.project_uuid, None)
        save_registry(reg_path, registry)

    summary = ", ".join(f"{count} {kind}" for kind, count in sorted(tally.items()))
    print(f"\n{summary or 'nothing to do'} ({skipped} unchanged)")
    return 0


def rebuild_state_command(
    args,
    load_todos: Callable[[], list[ThingsTodo]] | None = None,
    load_projects: Callable[[], list[ThingsProject]] | None = None,
) -> int:
    """Reconstruct the registry and every state file from calendar contents.

    Attribution is contents-first, same as the rest of the identity model: a
    calendar is a project's list because its markers say so, not because its
    title happens to match. Title is only the last resort, for a list with no
    markers at all. Every case this cannot resolve on its own — an orphaned
    marker, an empty unattributable list, one project's markers split across
    two lists — is named and reported rather than silently guessed at.
    """
    from thingsync.registry import Registry, RegistryEntry, registry_path, save as save_registry
    from thingsync.state import inbox_state_path, project_state_path, save as save_state

    if load_todos is None:
        from thingsync.things_source import load_todos
    if load_projects is None:
        from thingsync.things_source import load_projects

    sink, manager = _open_reminders()
    projects = load_projects()
    todos = load_todos()
    todo_by_uuid = {todo.uuid: todo for todo in todos}
    project_by_uuid = {project.uuid: project for project in projects}

    existing_calendars = manager.all_calendars()
    scans = manager.scan(existing_calendars)

    by_project: dict[str, list[tuple]] = {}
    inbox_candidates: list[tuple] = []
    unattributed: list[tuple] = []
    orphans_by_title: dict[str, list[str]] = {}

    for calendar, scan in zip(existing_calendars, scans):
        found_projects = set()
        found_inbox = False
        orphans = []

        for uuid in scan.marked:
            todo = todo_by_uuid.get(uuid)
            if todo is None:
                orphans.append(uuid)
            elif todo.project_uuid is not None:
                found_projects.add(todo.project_uuid)
            else:
                found_inbox = True

        if orphans:
            orphans_by_title[scan.title] = orphans

        if len(found_projects) > 1:
            print(f"  ambiguous  {scan.title!r} carries markers for {len(found_projects)} different projects; left as-is")
            unattributed.append((calendar, scan))
        elif len(found_projects) == 1:
            (project_uuid,) = found_projects
            by_project.setdefault(project_uuid, []).append((calendar, scan))
        elif found_inbox:
            inbox_candidates.append((calendar, scan))
        else:
            # No markers at all (or only orphans): title is the only signal left.
            title_matches = [p for p in projects if list_title_for_project(p) == scan.title]
            if len(title_matches) == 1:
                by_project.setdefault(title_matches[0].uuid, []).append((calendar, scan))
            elif scan.title == FALLBACK_LIST_TITLE:
                inbox_candidates.append((calendar, scan))
            else:
                unattributed.append((calendar, scan))

    reg_path = registry_path()
    registry = Registry()
    recovered = 0

    for project_uuid, entries in by_project.items():
        project = project_by_uuid.get(project_uuid)
        name = project.title if project else project_uuid
        if len(entries) > 1:
            names = ", ".join(repr(scan.title) for _, scan in entries)
            print(f"      split  project {name!r}'s markers are split across {len(entries)} lists ({names}); resolve by hand, then rebuild-state again")
            continue

        calendar, scan = entries[0]
        items = {
            uuid: StateEntry(identifier, "")
            for uuid, identifier in scan.marked.items()
            if todo_by_uuid.get(uuid) is not None and todo_by_uuid[uuid].project_uuid == project_uuid
        }
        title = list_title_for_project(project) if project else scan.title
        save_state(project_state_path(project_uuid), State(target_list=title, items=items, project_uuid=project_uuid))
        registry.projects[project_uuid] = RegistryEntry(calendar.calendarIdentifier(), scan.title)
        recovered += len(items)

    if len(inbox_candidates) > 1:
        names = ", ".join(repr(scan.title) for _, scan in inbox_candidates)
        print(f"      split  to-dos with no project are marked across {len(inbox_candidates)} lists ({names}); resolve by hand, then rebuild-state again")
    elif inbox_candidates:
        _, scan = inbox_candidates[0]
        items = {
            uuid: StateEntry(identifier, "")
            for uuid, identifier in scan.marked.items()
            if todo_by_uuid.get(uuid) is not None and todo_by_uuid[uuid].project_uuid is None
        }
        save_state(inbox_state_path(), State(target_list=FALLBACK_LIST_TITLE, items=items, project_uuid=None))
        recovered += len(items)

    for title, uuids in orphans_by_title.items():
        print(f"     orphan  {title!r} has marker(s) for to-do(s) no longer in Things: {', '.join(sorted(uuids))} (left as-is)")

    for _, scan in unattributed:
        print(f"unattributed  {scan.title!r}: no markers and no matching project title; left as-is")

    save_registry(reg_path, registry)
    print(f"\nRecovered {recovered} mappings across {len(existing_calendars)} lists into {reg_path.parent}")
    return 0


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)

    if args.command == "doctor":
        from thingsync.doctor import run_doctor

        lines, code = run_doctor()
        print("\n".join(lines))
        return code

    from thingsync.reminders_sink import RemindersError
    from thingsync.state import StateError

    try:
        if args.command == "sync":
            return sync_command(args)
        if args.command == "rebuild-state":
            return rebuild_state_command(args)
    except StateError as error:
        print(f"State error: {error}", file=sys.stderr)
        return 1
    except RemindersError as error:
        print(f"Reminders error: {error}", file=sys.stderr)
        return 1

    return 2


if __name__ == "__main__":
    sys.exit(main())
