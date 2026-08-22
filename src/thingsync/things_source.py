"""Adapter: things.py's dicts in, :class:`ThingsTodo` out.

One of only two modules that touch the outside world. The readers are injected
so the whole transformation — including breadcrumb resolution — is testable
without a Things database.
"""

from __future__ import annotations

from collections.abc import Callable, Iterable, Mapping

from thingsync.model import ThingsTodo


def _default_tasks(**kwargs):
    import things

    return things.tasks(**kwargs)


def _default_projects(**kwargs):
    import things

    return things.projects(**kwargs)


def load_todos(
    tasks: Callable[..., Iterable[Mapping]] | None = None,
    projects: Callable[..., Iterable[Mapping]] | None = None,
) -> list[ThingsTodo]:
    """Every open to-do, with its breadcrumb resolved."""
    tasks = tasks or _default_tasks
    projects = projects or _default_projects

    area_of_project = {
        project["uuid"]: project.get("area_title") for project in projects()
    }
    heading_parents = {
        heading["uuid"]: (heading.get("project_title"), area_of_project.get(heading.get("project")))
        for heading in tasks(type="heading", status="incomplete")
    }

    rows = tasks(type="to-do", status="incomplete", include_items=True)

    return [_to_todo(row, heading_parents, area_of_project) for row in rows]


def _breadcrumb_fields(
    row: Mapping,
    heading_parents: Mapping[str, tuple[str | None, str | None]],
    area_of_project: Mapping[str, str | None],
) -> tuple[str | None, str | None, str | None]:
    """Resolve ``(area, project, heading)`` for one to-do.

    things.py sets ``heading_title`` *or* ``project_title`` on a to-do, never
    both, and never sets ``area_title`` on a to-do owned by a project. So the
    upper levels are looked up rather than read off the row.
    """
    heading_title = row.get("heading_title")
    if heading_title:
        project_title, area_title = heading_parents.get(row.get("heading"), (None, None))
        return area_title, project_title, heading_title

    project_title = row.get("project_title")
    if project_title:
        return area_of_project.get(row.get("project")), project_title, None

    return row.get("area_title"), None, None


def _outstanding_checklist(row: Mapping) -> tuple[str, ...]:
    """The checklist items still to do.

    Completed items are dropped rather than mirrored: they render as "☐ item",
    which would show finished work as outstanding.
    """
    return tuple(
        item["title"]
        for item in row.get("checklist") or ()
        if item.get("status") != "completed"
    )


def _to_todo(
    row: Mapping,
    heading_parents: Mapping[str, tuple[str | None, str | None]],
    area_of_project: Mapping[str, str | None],
) -> ThingsTodo:
    area_title, project_title, heading_title = _breadcrumb_fields(
        row, heading_parents, area_of_project
    )
    return ThingsTodo(
        uuid=row["uuid"],
        title=row.get("title") or "",
        notes=row.get("notes"),
        area_title=area_title,
        project_title=project_title,
        heading_title=heading_title,
        tags=tuple(row.get("tags") or ()),
        checklist=_outstanding_checklist(row),
        deadline=row.get("deadline"),
        start_date=row.get("start_date"),
    )
