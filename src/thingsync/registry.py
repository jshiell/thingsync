"""The project registry: which Reminders list mirrors which Things project.

Unlike a reminder, an ``EKCalendar`` carries no in-band identity marker — no
notes, no URL, nothing writable that isn't user-visible (see plan.md, "Why
list identity is a harder problem than reminder identity"). So list identity
is recovered primarily from a calendar's own contents, and this registry is
only ever a fast-path cache on top of that, exactly as the state store is a
cache for reminder identity: losing it is recoverable, corrupting it is not
silently tolerated.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from pathlib import Path

from thingsync.state import state_root

VERSION = 1
REGISTRY_FILENAME = "_projects.json"

REPAIR_HINT = "run `thingsync rebuild-state` to reconstruct it from your Reminders lists"


class RegistryError(Exception):
    """The project registry exists but cannot be trusted.

    Never downgraded to "start fresh": a blank registry next to a Reminders
    list still full of markered reminders is the same mass-duplication path
    the state store's ``StateError`` exists to avoid.
    """


@dataclass(frozen=True)
class RegistryEntry:
    """What we recorded about one project's list.

    ``calendar_id`` is a fast path only, never the key: it is cross-checked
    (or recovered) by scanning calendar contents for the project's markers.
    """

    calendar_id: str | None
    title: str


@dataclass
class Registry:
    projects: dict[str, RegistryEntry] = field(default_factory=dict)


def registry_path(root: Path | None = None) -> Path:
    return (root or state_root()) / REGISTRY_FILENAME


def save(path: Path, registry: Registry) -> None:
    """Write the registry atomically: temp file alongside, then ``os.replace``."""
    path.parent.mkdir(parents=True, exist_ok=True)
    document = {
        "version": VERSION,
        "projects": {
            uuid: {"calendar_id": entry.calendar_id, "title": entry.title}
            for uuid, entry in registry.projects.items()
        },
    }
    temp = path.with_name(path.name + ".tmp")
    temp.write_text(json.dumps(document, indent=2, sort_keys=True), encoding="utf-8")
    os.replace(temp, path)


def load(path: Path) -> Registry:
    """Read the project registry, or an empty one if none exists yet."""
    if not path.exists():
        return Registry(projects={})

    try:
        document = json.loads(path.read_text(encoding="utf-8"))
        version = document["version"]
        projects = {
            uuid: RegistryEntry(calendar_id=entry.get("calendar_id"), title=entry["title"])
            for uuid, entry in document["projects"].items()
        }
    except (
        json.JSONDecodeError,
        KeyError,
        TypeError,
        AttributeError,
        UnicodeDecodeError,
        OSError,
    ) as error:
        raise RegistryError(f"{path} is not a readable thingsync project registry ({error}); {REPAIR_HINT}") from error

    if version != VERSION:
        raise RegistryError(f"{path} is registry version {version}, but this thingsync understands version {VERSION}; {REPAIR_HINT}")

    return Registry(projects=projects)
