"""The core decision for list identity: given Things' projects, the registry
and a picture of what Reminders already has, what should happen to each
project's list?

Pure by construction, same as :mod:`thingsync.planner` is for reminders. Every
fact about the outside world is passed in as a :class:`CalendarInfo`: which
calendars exist, which project UUIDs their contents attest to (the global
marker scan, joined against each to-do's ``project_uuid`` by the caller), and
whether any reminder in them cannot be proven to be thingsync's own.
"""

from __future__ import annotations

from collections.abc import Iterable
from dataclasses import dataclass
from enum import Enum

from thingsync.mapping import list_title_for_project
from thingsync.model import ThingsProject
from thingsync.registry import Registry, RegistryEntry

# How far a project read can fall short of the registry's known projects
# before it looks like a failed or partial read rather than genuine project
# closure. A registry with no entries yet is never implausible.
IMPLAUSIBLE_READ_RATIO = 0.5


class ListActionKind(Enum):
    CREATE_LIST = "create_list"
    RENAME_LIST = "rename_list"
    ADOPT_LIST = "adopt_list"
    DELETE_LIST = "delete_list"
    KEEP = "keep"


@dataclass(frozen=True)
class ListAction:
    kind: ListActionKind
    project_uuid: str
    title: str
    calendar_id: str | None = None
    # Set only on a KEEP that stands in for a refused deletion: reported every
    # run so a safety refusal is never silently swallowed.
    reason: str | None = None


@dataclass(frozen=True)
class CalendarInfo:
    """One Reminders calendar, as seen from EventKit — pure data, no PyObjC."""

    calendar_id: str
    title: str
    attested_project_uuids: frozenset[str]
    has_foreign_reminder: bool


def _read_looks_implausible(projects: Iterable[ThingsProject], registry: Registry) -> bool:
    known = len(registry.projects)
    if known == 0:
        return False
    seen = len({project.uuid for project in projects})
    return seen < known * IMPLAUSIBLE_READ_RATIO


def _resolve_calendar(
    project_uuid: str,
    entry: RegistryEntry | None,
    title: str,
    calendars: list[CalendarInfo],
    claimed: set[str],
) -> CalendarInfo | None:
    """Recover the calendar mirroring ``project_uuid``, contents first.

    1. an unambiguous marker match, from the global scan grouped by calendar;
    2. the cached ``calendar_id``, but only once contents evidence is absent —
       it is a fast path, never sole truth;
    3. an unambiguous title match among calendars not already claimed this
       run — the last, weakest resort, since Things allows duplicate project
       titles.
    """
    attested = [c for c in calendars if project_uuid in c.attested_project_uuids]
    if len(attested) == 1:
        return attested[0]
    if len(attested) > 1:
        if entry is not None:
            cached = next((c for c in attested if c.calendar_id == entry.calendar_id), None)
            if cached is not None:
                return cached
        return min(attested, key=lambda c: c.calendar_id)

    if entry is not None:
        cached = next((c for c in calendars if c.calendar_id == entry.calendar_id), None)
        if cached is not None:
            return cached

    title_matches = [c for c in calendars if c.title == title and c.calendar_id not in claimed]
    if len(title_matches) == 1:
        return title_matches[0]

    return None


def plan_lists(
    projects: Iterable[ThingsProject],
    registry: Registry,
    calendars: Iterable[CalendarInfo],
) -> list[ListAction]:
    """Decide what to do about every project's list, and every registered
    list whose project is no longer open."""
    projects = list(projects)
    calendars = list(calendars)
    by_id = {calendar.calendar_id: calendar for calendar in calendars}
    implausible = _read_looks_implausible(projects, registry)

    # Every calendar this run already knows the owner of, so a title-fallback
    # never hands one project's registered list to another.
    claimed = {entry.calendar_id for entry in registry.projects.values() if entry.calendar_id}

    open_projects = {p.uuid: p for p in projects if p.status == "incomplete"}
    actions: list[ListAction] = []

    for project_uuid, project in open_projects.items():
        entry = registry.projects.get(project_uuid)
        title = list_title_for_project(project)

        calendar = _resolve_calendar(project_uuid, entry, title, calendars, claimed)

        if calendar is None:
            actions.append(ListAction(ListActionKind.CREATE_LIST, project_uuid, title))
            continue

        claimed.add(calendar.calendar_id)
        known_id = entry.calendar_id if entry is not None else None

        if known_id != calendar.calendar_id:
            actions.append(ListAction(ListActionKind.ADOPT_LIST, project_uuid, title, calendar.calendar_id))
        elif calendar.title != title:
            actions.append(ListAction(ListActionKind.RENAME_LIST, project_uuid, title, calendar.calendar_id))
        else:
            actions.append(ListAction(ListActionKind.KEEP, project_uuid, title, calendar.calendar_id))

    for project_uuid, entry in registry.projects.items():
        if project_uuid in open_projects:
            continue
        calendar = by_id.get(entry.calendar_id) if entry.calendar_id else None
        if calendar is None:
            # No live calendar to delete or refuse on; nothing to act on.
            continue

        if implausible:
            actions.append(
                ListAction(
                    ListActionKind.KEEP,
                    project_uuid,
                    calendar.title,
                    calendar.calendar_id,
                    reason=(
                        "the Things project read looks implausibly empty; "
                        "refusing all list deletions this run"
                    ),
                )
            )
        elif calendar.has_foreign_reminder:
            actions.append(
                ListAction(
                    ListActionKind.KEEP,
                    project_uuid,
                    calendar.title,
                    calendar.calendar_id,
                    reason="a foreign (hand-made) reminder is in this list; refusing to delete it",
                )
            )
        else:
            actions.append(
                ListAction(ListActionKind.DELETE_LIST, project_uuid, calendar.title, calendar.calendar_id)
            )

    return actions
