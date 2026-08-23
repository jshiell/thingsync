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


class LegacyStateError(StateError):
    """State from the single-list build is present.

    Adopting it silently would mean the per-project scans never look at the old
    calendar, so every to-do gets recreated fresh in its project list while the
    old markered copies sit there untouched: permanent duplication delivered by
    the upgrade itself. Refused until the operator migrates by hand.
    """


LEGACY_MIGRATION_HINT = (
    "thingsync now mirrors one Reminders list per Things project instead of one "
    "shared list. To migrate: (1) in the Reminders app, delete the list thingsync "
    "used to write into; (2) delete the state file(s) named above; (3) re-run "
    "`thingsync sync` to build fresh per-project lists."
)

KNOWN_ROOT_FILES: frozenset[str] = frozenset({"_projects.json", "inbox.json"})


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
    project_uuid: str | None = None


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


PROJECTS_SUBDIR = "projects"
INBOX_STATE_FILENAME = "inbox.json"


def project_state_path(project_uuid: str, root: Path | None = None) -> Path:
    """One state file per Things project, keyed by UUID rather than its
    (mutable) title, under its own subdirectory so it is never mistaken for a
    leftover single-list state file."""
    return (root or state_root()) / PROJECTS_SUBDIR / f"{project_uuid}.json"


def inbox_state_path(root: Path | None = None) -> Path:
    """The one fixed state file for to-dos with no project."""
    return (root or state_root()) / INBOX_STATE_FILENAME


def save(path: Path, state: State) -> None:
    """Write the state atomically: temp file alongside, then ``os.replace``."""
    path.parent.mkdir(parents=True, exist_ok=True)
    document = {
        "version": VERSION,
        "target_list": state.target_list,
        "project_uuid": state.project_uuid,
        "items": {
            uuid: {"reminder_id": entry.reminder_id, "hash": entry.hash}
            for uuid, entry in state.items.items()
        },
    }
    temp = path.with_name(path.name + ".tmp")
    temp.write_text(json.dumps(document, indent=2, sort_keys=True), encoding="utf-8")
    os.replace(temp, path)


def load(path: Path, target_list: str, project_uuid: str | None = None) -> State:
    """Read the state for ``target_list``, or an empty state if none exists yet.

    The mismatch guard keys on ``project_uuid`` whenever either side has one,
    since a project's title can be renamed in Things at any time; only when
    neither side carries a project_uuid does it fall back to the older,
    title-based guard.
    """
    if not path.exists():
        return State(target_list=target_list, items={}, project_uuid=project_uuid)

    try:
        document = json.loads(path.read_text(encoding="utf-8"))
        version = document["version"]
        stored_list = document["target_list"]
        stored_project_uuid = document.get("project_uuid")
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

    if project_uuid is not None or stored_project_uuid is not None:
        if stored_project_uuid != project_uuid:
            raise StateError(
                f"{path} holds state for project {stored_project_uuid!r}, but project "
                f"{project_uuid!r} was requested; refusing to apply one project's mappings to another"
            )
    elif stored_list != target_list:
        raise StateError(f"{path} holds state for list {stored_list!r}, but list {target_list!r} was requested; refusing to apply one list's mappings to another")

    return State(target_list=stored_list, items=items, project_uuid=stored_project_uuid)


def legacy_state_files(root: Path | None = None) -> list[Path]:
    """State files left over from the single-list build.

    The per-project layout keeps every state file either under a ``projects/``
    subdirectory or under one of ``KNOWN_ROOT_FILES``; anything else sitting as
    JSON directly in the state root predates that and is not eligible for
    silent adoption.
    """
    root = root or state_root()
    if not root.is_dir():
        return []
    return sorted(p for p in root.glob("*.json") if p.name not in KNOWN_ROOT_FILES)


def check_for_legacy_state(root: Path | None = None) -> None:
    """Refuse to run against a single-list state layout.

    Called before anything else in ``sync``, so no per-project code can ever
    run against state it would silently duplicate.
    """
    files = legacy_state_files(root)
    if not files:
        return
    names = ", ".join(path.name for path in files)
    raise LegacyStateError(
        f"found old single-list state file(s) in {root or state_root()}: {names}. "
        f"{LEGACY_MIGRATION_HINT}"
    )
