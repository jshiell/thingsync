"""The core decision: given Things, the state and a scan of the target list,
what should happen to each reminder?

Pure by construction. Every fact about the outside world — which reminders
every thingsync-owned calendar already carries, and which cached identifiers
still resolve (and where) — is passed in, so the whole algorithm is testable
without EventKit.

This plans across *every* project's to-dos and calendar at once, not one list
at a time: a to-do whose project changed needs to be told apart from one that
was simply deleted, and per-list planning cannot do that — it would see the
to-do vanish from its old list (-> COMPLETE) and reappear as brand new in its
new one (-> CREATE), duplicating it permanently. See plan.md, "New identity
flows".
"""

from __future__ import annotations

from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from enum import Enum

from thingsync.mapping import to_payload
from thingsync.model import ReminderPayload, ThingsTodo
from thingsync.state import StateEntry


class ActionKind(Enum):
    CREATE = "create"
    ADOPT = "adopt"
    UPDATE = "update"
    MOVE = "move"
    SKIP = "skip"
    COMPLETE = "complete"
    DELETE = "delete"
    FORGET = "forget"


@dataclass(frozen=True)
class SyncAction:
    kind: ActionKind
    uuid: str
    payload: ReminderPayload | None = None
    reminder_id: str | None = None
    calendar_id: str | None = None


def resolve(
    uuid: str,
    cached: StateEntry | None,
    markers: Mapping[str, tuple[str, str]],
    live: Mapping[str, str],
) -> tuple[str, str] | None:
    """Find the reminder mirroring ``uuid``, in the order the plan prescribes.

    1. the cached ``calendarItemIdentifier``, if it still resolves — ``live``
       maps a resolving identifier to the calendar it is *actually* in now,
       which is what makes a hand-moved or project-changed reminder visible
       as such rather than silently "still fine, still here";
    2. otherwise a marker carrying this Things UUID, found by the global scan.

    Step 2 is what tells "the user deleted it" apart from "iCloud rotated the
    identifier". It must never collapse into "absent". Returns
    ``(calendar_id, reminder_id)`` — the calendar the reminder is *actually*
    in — or ``None`` if nothing can be found.
    """
    if cached is not None and cached.reminder_id in live:
        return live[cached.reminder_id], cached.reminder_id
    return markers.get(uuid)


def plan(
    todos: Iterable[ThingsTodo],
    items: Mapping[str, StateEntry],
    markers: Mapping[str, tuple[str, str]],
    live: Mapping[str, str],
    calendar_for_project: Mapping[str | None, str],
    on_done: str = "complete",
) -> list[SyncAction]:
    """Decide what to do about every open to-do, and every to-do that has
    stopped being one, across every project at once."""
    actions: list[SyncAction] = []
    todos = list(todos)

    for todo in todos:
        target_calendar = calendar_for_project[todo.project_uuid]
        payload = to_payload(todo, in_project_list=todo.project_uuid is not None)
        cached = items.get(todo.uuid)
        found = resolve(todo.uuid, cached, markers, live)

        if found is None:
            # Either never mirrored, or mirrored and since deleted by hand. Both
            # reduce to the same thing: there is nothing out there to update.
            actions.append(SyncAction(ActionKind.CREATE, todo.uuid, payload=payload, calendar_id=target_calendar))
            continue

        found_calendar, reminder_id = found

        if found_calendar != target_calendar:
            # Found, but in the wrong list: the to-do's project changed since
            # it was last mirrored. Relocating it is the only way to avoid
            # completing the old copy and creating a duplicate in the new list.
            actions.append(
                SyncAction(ActionKind.MOVE, todo.uuid, payload=payload, reminder_id=reminder_id, calendar_id=target_calendar)
            )
        elif cached is None or cached.reminder_id != reminder_id:
            # Found by marker rather than by cached identifier, so the mapping is
            # new or stale. Re-record it and write the payload.
            actions.append(
                SyncAction(ActionKind.ADOPT, todo.uuid, payload=payload, reminder_id=reminder_id, calendar_id=target_calendar)
            )
        elif cached.hash != payload.content_hash():
            actions.append(
                SyncAction(ActionKind.UPDATE, todo.uuid, payload=payload, reminder_id=reminder_id, calendar_id=target_calendar)
            )
        else:
            actions.append(SyncAction(ActionKind.SKIP, todo.uuid, reminder_id=reminder_id, calendar_id=target_calendar))

    open_uuids = {todo.uuid for todo in todos}
    closing = ActionKind.DELETE if on_done == "delete" else ActionKind.COMPLETE

    for uuid, cached in items.items():
        if uuid in open_uuids:
            continue
        # Completed, cancelled, trashed or simply gone from Things.
        found = resolve(uuid, cached, markers, live)
        if found is None:
            # Nothing left to act on; just stop tracking it.
            actions.append(SyncAction(ActionKind.FORGET, uuid))
        else:
            _, reminder_id = found
            actions.append(SyncAction(closing, uuid, reminder_id=reminder_id))

    return actions


DESTRUCTIVE = frozenset({ActionKind.COMPLETE, ActionKind.DELETE})


def destructive_actions(actions: Iterable[SyncAction]) -> list[SyncAction]:
    """The actions that remove work from the user's list.

    A planner bug should not be able to silently clear a list, so the CLI gates
    these behind ``--yes`` once there are more than a handful.
    """
    return [action for action in actions if action.kind in DESTRUCTIVE]
