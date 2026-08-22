"""The core decision: given Things, the state and a scan of the target list,
what should happen to each reminder?

Pure by construction. Every fact about the outside world — which reminders the
target list already carries, and which cached identifiers still resolve — is
passed in, so the whole algorithm is testable without EventKit.
"""

from __future__ import annotations

from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from enum import Enum

from thingsync.mapping import to_payload
from thingsync.model import ReminderPayload, ThingsTodo
from thingsync.state import State


class ActionKind(Enum):
    CREATE = "create"
    ADOPT = "adopt"
    UPDATE = "update"
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


def resolve(
    uuid: str,
    state: State,
    markers: Mapping[str, str],
    live_ids: set[str],
) -> str | None:
    """Find the reminder mirroring ``uuid``, in the order the plan prescribes.

    1. the cached ``calendarItemIdentifier``, if it still resolves;
    2. otherwise a marker carrying this Things UUID, found by scanning the list.

    Step 2 is what tells "the user deleted it" apart from "iCloud rotated the
    identifier". It must never collapse into "absent".
    """
    entry = state.items.get(uuid)
    if entry and entry.reminder_id in live_ids:
        return entry.reminder_id
    return markers.get(uuid)


def plan(
    todos: Iterable[ThingsTodo],
    state: State,
    markers: Mapping[str, str],
    live_ids: set[str],
    on_done: str = "complete",
) -> list[SyncAction]:
    """Decide what to do about every open to-do, and every to-do that has stopped
    being one."""
    actions: list[SyncAction] = []
    todos = list(todos)

    for todo in todos:
        payload = to_payload(todo)
        entry = state.items.get(todo.uuid)
        reminder_id = resolve(todo.uuid, state, markers, live_ids)

        if reminder_id is None:
            # Either never mirrored, or mirrored and since deleted by hand. Both
            # reduce to the same thing: there is nothing out there to update.
            actions.append(SyncAction(ActionKind.CREATE, todo.uuid, payload=payload))
        elif entry is None or entry.reminder_id != reminder_id:
            # Found by marker rather than by cached identifier, so the mapping is
            # new or stale. Re-record it and write the payload.
            actions.append(
                SyncAction(
                    ActionKind.ADOPT,
                    todo.uuid,
                    payload=payload,
                    reminder_id=reminder_id,
                )
            )
        elif entry.hash != payload.content_hash():
            actions.append(
                SyncAction(
                    ActionKind.UPDATE,
                    todo.uuid,
                    payload=payload,
                    reminder_id=reminder_id,
                )
            )
        else:
            actions.append(
                SyncAction(ActionKind.SKIP, todo.uuid, reminder_id=reminder_id)
            )

    open_uuids = {todo.uuid for todo in todos}
    closing = ActionKind.DELETE if on_done == "delete" else ActionKind.COMPLETE

    for uuid in state.items:
        if uuid in open_uuids:
            continue
        # Completed, cancelled, trashed or simply gone from Things.
        reminder_id = resolve(uuid, state, markers, live_ids)
        if reminder_id is None:
            # Nothing left to act on; just stop tracking it.
            actions.append(SyncAction(ActionKind.FORGET, uuid))
        else:
            actions.append(SyncAction(closing, uuid, reminder_id=reminder_id))

    return actions


DESTRUCTIVE = frozenset({ActionKind.COMPLETE, ActionKind.DELETE})


def destructive_actions(actions: Iterable[SyncAction]) -> list[SyncAction]:
    """The actions that remove work from the user's list.

    A planner bug should not be able to silently clear a list, so the CLI gates
    these behind ``--yes`` once there are more than a handful.
    """
    return [action for action in actions if action.kind in DESTRUCTIVE]
