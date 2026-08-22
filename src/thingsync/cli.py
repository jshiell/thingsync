"""Command line entry point."""

from __future__ import annotations

import argparse
import sys
from collections import Counter
from collections.abc import Callable, Iterable

from thingsync.planner import ActionKind, SyncAction, destructive_actions
from thingsync.protocols import ReminderSink
from thingsync.state import State, StateEntry

DEFAULT_LIST = "Things"
DESTRUCTIVE_THRESHOLD = 10


def refusal_for_bulk_destruction(
    actions: Iterable[SyncAction], assume_yes: bool
) -> str | None:
    """Refuse to clear a list wholesale unless explicitly authorised.

    A planner bug, a half-read database or the wrong ``--list`` should not be
    able to silently empty someone's reminders.
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
    state: State,
    persist: Callable[[State], None],
) -> Counter:
    """Carry out the plan, recording each success before moving on.

    The state is persisted after every action rather than once at the end: a
    crash partway through must not leave created reminders unrecorded.
    """
    tally: Counter = Counter()

    for action in actions:
        if action.kind is ActionKind.CREATE:
            identifier = sink.create(action.payload)
            state.items[action.uuid] = StateEntry(
                identifier, action.payload.content_hash()
            )
        elif action.kind in (ActionKind.ADOPT, ActionKind.UPDATE):
            sink.update(action.reminder_id, action.payload)
            state.items[action.uuid] = StateEntry(
                action.reminder_id, action.payload.content_hash()
            )
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
        persist(state)

    return tally


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="thingsync",
        description="One-way mirror from Things 3 to Apple Reminders.",
    )
    commands = parser.add_subparsers(dest="command", required=True)

    commands.add_parser("doctor", help="check the permissions thingsync needs")

    sync = commands.add_parser("sync", help="mirror open Things to-dos into Reminders")
    sync.add_argument("--list", dest="target_list", default=DEFAULT_LIST,
                      help=f"target Reminders list (default: {DEFAULT_LIST})")
    sync.add_argument("--dry-run", action="store_true",
                      help="print the plan and write nothing")
    sync.add_argument("--on-done", choices=("complete", "delete"), default="complete",
                      help="what to do with reminders whose to-do is no longer open")
    sync.add_argument("--yes", action="store_true",
                      help="authorise bulk completion or deletion")

    rebuild = commands.add_parser(
        "rebuild-state",
        help="reconstruct the state file by scanning the target list for markers",
    )
    rebuild.add_argument("--list", dest="target_list", default=DEFAULT_LIST)

    return parser


def describe(action: SyncAction) -> str:
    title = action.payload.title if action.payload else action.uuid
    return f"{action.kind.value:>8}  {title}"


def _open_sink(target_list: str):
    from thingsync.reminders_sink import RemindersSink

    sink = RemindersSink(target_list)
    sink.request_access()
    return sink


def sync_command(args) -> int:
    from thingsync.planner import plan
    from thingsync.state import load, save, state_path
    from thingsync.things_source import load_todos

    path = state_path(args.target_list)
    state = load(path, target_list=args.target_list)
    todos = load_todos()

    sink = _open_sink(args.target_list)
    markers = sink.scan_markers()
    live_ids = sink.resolve_live(entry.reminder_id for entry in state.items.values())

    actions = plan(todos, state, markers, live_ids, on_done=args.on_done)
    interesting = [a for a in actions if a.kind is not ActionKind.SKIP]

    for action in interesting:
        print(describe(action))
    skipped = len(actions) - len(interesting)

    if args.dry_run:
        print(f"\n{len(interesting)} actions, {skipped} unchanged. Nothing written (--dry-run).")
        return 0

    refusal = refusal_for_bulk_destruction(actions, assume_yes=args.yes)
    if refusal:
        print(f"\nRefusing: {refusal}", file=sys.stderr)
        return 1

    tally = execute(actions, sink, state, lambda s: save(path, s))
    summary = ", ".join(f"{count} {kind}" for kind, count in sorted(tally.items()))
    print(f"\n{summary or 'nothing to do'} ({skipped} unchanged)")
    return 0


def rebuild_state_command(args) -> int:
    from thingsync.state import save, state_path

    sink = _open_sink(args.target_list)
    markers = sink.scan_markers()

    # The payload hash is deliberately left unmatchable: the next sync will
    # rewrite every adopted reminder rather than assume it is already correct.
    state = State(
        target_list=args.target_list,
        items={uuid: StateEntry(identifier, "") for uuid, identifier in markers.items()},
    )
    path = state_path(args.target_list)
    save(path, state)

    print(f"Recovered {len(markers)} mappings from {args.target_list!r} into {path}")
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
