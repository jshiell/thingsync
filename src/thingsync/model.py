"""The data carried between the Things source and the Reminders sink."""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from datetime import date


@dataclass(frozen=True)
class ThingsTodo:
    """One open to-do, as read from the Things database.

    ``area_title`` / ``project_title`` / ``heading_title`` are the human-readable
    names; the bare ``area``/``project`` fields in things.py are UUIDs and are of
    no use to us.
    """

    uuid: str
    title: str
    notes: str | None = None
    area_title: str | None = None
    project_title: str | None = None
    heading_title: str | None = None
    project_uuid: str | None = None
    tags: tuple[str, ...] = ()
    checklist: tuple[str, ...] = ()
    deadline: str | None = None
    start_date: str | None = None


@dataclass(frozen=True)
class ThingsProject:
    """One Things project, open or not — the per-project Reminders list source."""

    uuid: str
    title: str
    status: str


@dataclass(frozen=True)
class ReminderPayload:
    """Everything thingsync writes onto a reminder."""

    title: str
    notes: str
    url: str
    due_date: date | None = None
    start_date: date | None = None

    def content_hash(self) -> str:
        """A stable digest of the payload, used to detect that nothing changed."""
        material = json.dumps(
            {
                "title": self.title,
                "notes": self.notes,
                "url": self.url,
                "due_date": self.due_date.isoformat() if self.due_date else None,
                "start_date": self.start_date.isoformat() if self.start_date else None,
            },
            sort_keys=True,
            ensure_ascii=False,
        )
        return hashlib.sha256(material.encode("utf-8")).hexdigest()
