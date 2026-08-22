"""The state store: a per-target-list cache of what has already been mirrored.

The store is only ever a *cache*. Durable identity lives in band, on the reminder
itself (see :mod:`thingsync.mapping`), which is why losing this file is
recoverable and corrupting it is not silently tolerated.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
import re
from pathlib import Path

VERSION = 1

REPAIR_HINT = "run `thingsync rebuild-state` to reconstruct it from the target list"


class StateError(Exception):
    """The state file exists but cannot be trusted.

    Never downgraded to "start fresh": an empty state plus a present list is the
    mass-duplication path this whole design exists to avoid.
    """


@dataclass(frozen=True)
class StateEntry:
    """What we recorded about one mirrored to-do.

    ``reminder_id`` is a ``calendarItemIdentifier``, which Apple documents as
    *local* — a full iCloud sync discards it. It is a fast path, never the key.
    """

    reminder_id: str
    hash: str


@dataclass
class State:
    target_list: str
    items: dict[str, StateEntry] = field(default_factory=dict)


DEFAULT_ROOT = Path.home() / ".local" / "state" / "thingsync"
STATE_DIR_VARIABLE = "THINGSYNC_STATE_DIR"


def state_root() -> Path:
    """Where state files live, overridable for sandboxes and tests."""
    return Path(os.environ.get(STATE_DIR_VARIABLE) or DEFAULT_ROOT)


def state_path(target_list: str, root: Path | None = None) -> Path:
    """One state file per target list.

    ``--list`` is a per-run flag, so a single global file would let a run against
    one list leave mappings that a later run applies to a different one.
    """
    slug = re.sub(r"[^A-Za-z0-9._-]+", "_", target_list).strip("._-") or "default"
    return (root or state_root()) / f"{slug}.json"


def save(path: Path, state: State) -> None:
    """Write the state atomically: temp file alongside, then ``os.replace``."""
    path.parent.mkdir(parents=True, exist_ok=True)
    document = {
        "version": VERSION,
        "target_list": state.target_list,
        "items": {
            uuid: {"reminder_id": entry.reminder_id, "hash": entry.hash}
            for uuid, entry in state.items.items()
        },
    }
    temp = path.with_name(path.name + ".tmp")
    temp.write_text(json.dumps(document, indent=2, sort_keys=True), encoding="utf-8")
    os.replace(temp, path)


def load(path: Path, target_list: str) -> State:
    """Read the state for ``target_list``, or an empty state if none exists yet."""
    if not path.exists():
        return State(target_list=target_list, items={})

    try:
        document = json.loads(path.read_text(encoding="utf-8"))
        version = document["version"]
        stored_list = document["target_list"]
        items = {
            uuid: StateEntry(reminder_id=entry["reminder_id"], hash=entry["hash"])
            for uuid, entry in document["items"].items()
        }
    except (
        json.JSONDecodeError,
        KeyError,
        TypeError,
        AttributeError,
        UnicodeDecodeError,
        OSError,
    ) as error:
        raise StateError(f"{path} is not a readable thingsync state file ({error}); {REPAIR_HINT}") from error

    if version != VERSION:
        raise StateError(f"{path} is state version {version}, but this thingsync understands version {VERSION}; {REPAIR_HINT}")

    if stored_list != target_list:
        raise StateError(f"{path} holds state for list {stored_list!r}, but list {target_list!r} was requested; refusing to apply one list's mappings to another")

    return State(target_list=stored_list, items=items)
