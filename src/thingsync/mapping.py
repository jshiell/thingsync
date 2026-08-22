"""Pure mapping from a Things to-do to the payload written to a reminder."""

from __future__ import annotations

from datetime import date
from urllib.parse import parse_qs, urlsplit

from thingsync.model import ReminderPayload, ThingsTodo

MARKER_SCHEME = "things"
MARKER_PATH = "/show"


def marker_url(uuid: str) -> str:
    """The durable, in-band identity marker written onto every mirrored reminder.

    Doubles as a working deep link back into Things.
    """
    return f"things:///show?id={uuid}"


def uuid_from_marker(url: str | None) -> str | None:
    """Recover the Things UUID from a marker URL, or None if it is not one."""
    if not url:
        return None
    parts = urlsplit(url)
    if parts.scheme != MARKER_SCHEME or parts.path != MARKER_PATH:
        return None
    ids = parse_qs(parts.query).get("id")
    return ids[0] if ids else None


def _parse_things_date(value: str | None) -> date | None:
    """Things hands out ``'YYYY-MM-DD'`` strings, not dates. Parse explicitly."""
    if not value:
        return None
    return date.fromisoformat(value)


BREADCRUMB_SEPARATOR = " › "
CHECKLIST_BULLET = "☐ "


def breadcrumb(todo: ThingsTodo) -> str:
    """``Area › Project › Heading``, skipping the levels the to-do does not have."""
    levels = (todo.area_title, todo.project_title, todo.heading_title)
    return BREADCRUMB_SEPARATOR.join(level for level in levels if level)


def compose_notes(todo: ThingsTodo) -> str:
    """Build the reminder's notes body.

    EventKit has no public API for tags or nested reminders, so the breadcrumb,
    checklist and tags are all flattened into this one text field.
    """
    blocks = [
        breadcrumb(todo),
        (todo.notes or "").strip(),
        "\n".join(CHECKLIST_BULLET + item for item in todo.checklist),
        " ".join("#" + tag for tag in todo.tags),
    ]
    return "\n\n".join(block for block in blocks if block)


def to_payload(todo: ThingsTodo) -> ReminderPayload:
    """Map a Things to-do onto the payload written to its mirrored reminder."""
    return ReminderPayload(
        title=todo.title,
        notes=compose_notes(todo),
        url=marker_url(todo.uuid),
        due_date=_parse_things_date(todo.deadline),
        start_date=_parse_things_date(todo.start_date),
    )
