import pytest

from thingsync.things_source import load_todos


class FakeThings:
    """Stands in for things.py, recording how it was called."""

    def __init__(self, todos=(), headings=(), projects=()):
        self._todos = list(todos)
        self._headings = list(headings)
        self._projects = list(projects)
        self.calls = []

    def tasks(self, **kwargs):
        self.calls.append(kwargs)
        return self._headings if kwargs.get("type") == "heading" else self._todos

    def projects(self, **kwargs):
        return self._projects


def test_scalar_fields_come_straight_across():
    fake = FakeThings(todos=[{"uuid": "U1", "title": "Buy milk", "notes": "2 pints",
                              "deadline": "2026-08-25", "start_date": "2026-08-20"}])

    (todo,) = load_todos(tasks=fake.tasks, projects=fake.projects)

    assert todo.uuid == "U1"
    assert todo.title == "Buy milk"
    assert todo.notes == "2 pints"
    assert todo.deadline == "2026-08-25"
    assert todo.start_date == "2026-08-20"


def test_checklists_are_requested_explicitly():
    # things.py defaults include_items to False, which would silently drop every
    # checklist rather than fail.
    fake = FakeThings(todos=[])

    load_todos(tasks=fake.tasks, projects=fake.projects)

    todo_call = next(c for c in fake.calls if c.get("type") == "to-do")
    assert todo_call["include_items"] is True


# things.py sets `heading_title` OR `project_title` on a to-do, never both, and
# never sets `area_title` on a to-do that lives in a project. Taken literally the
# three `_title` fields therefore cannot produce "Area › Project › Heading", so
# the chain is resolved here instead.

PROJECTS = [{"uuid": "P1", "title": "Website", "area_title": "Work"}]
HEADINGS = [{"uuid": "H1", "title": "Launch", "project": "P1", "project_title": "Website"}]


def test_a_todo_under_a_heading_recovers_its_project_and_area():
    fake = FakeThings(
        todos=[{"uuid": "U1", "title": "t", "heading": "H1", "heading_title": "Launch"}],
        headings=HEADINGS,
        projects=PROJECTS,
    )

    (todo,) = load_todos(tasks=fake.tasks, projects=fake.projects)

    assert (todo.area_title, todo.project_title, todo.heading_title) == (
        "Work",
        "Website",
        "Launch",
    )


def test_a_todo_directly_in_a_project_recovers_its_area():
    fake = FakeThings(
        todos=[{"uuid": "U1", "title": "t", "project": "P1", "project_title": "Website"}],
        headings=HEADINGS,
        projects=PROJECTS,
    )

    (todo,) = load_todos(tasks=fake.tasks, projects=fake.projects)

    assert (todo.area_title, todo.project_title, todo.heading_title) == (
        "Work",
        "Website",
        None,
    )


def test_a_todo_sitting_straight_in_an_area_keeps_that_area():
    fake = FakeThings(
        todos=[{"uuid": "U1", "title": "t", "area": "A1", "area_title": "Home"}],
        projects=PROJECTS,
    )

    (todo,) = load_todos(tasks=fake.tasks, projects=fake.projects)

    assert (todo.area_title, todo.project_title, todo.heading_title) == (
        "Home",
        None,
        None,
    )


def test_an_unfiled_todo_has_no_breadcrumb_at_all():
    fake = FakeThings(todos=[{"uuid": "U1", "title": "t"}])

    (todo,) = load_todos(tasks=fake.tasks, projects=fake.projects)

    assert (todo.area_title, todo.project_title, todo.heading_title) == (None, None, None)


def test_tags_become_a_tuple():
    fake = FakeThings(todos=[{"uuid": "U1", "title": "t", "tags": ["errand", "urgent"]}])

    (todo,) = load_todos(tasks=fake.tasks, projects=fake.projects)

    assert todo.tags == ("errand", "urgent")


def test_only_outstanding_checklist_items_are_mirrored():
    # A completed item rendered as "☐ item" would misrepresent it as outstanding.
    fake = FakeThings(
        todos=[
            {
                "uuid": "U1",
                "title": "t",
                "checklist": [
                    {"title": "pack bags", "status": "incomplete"},
                    {"title": "book taxi", "status": "completed"},
                    {"title": "print tickets", "status": "incomplete"},
                ],
            }
        ]
    )

    (todo,) = load_todos(tasks=fake.tasks, projects=fake.projects)

    assert todo.checklist == ("pack bags", "print tickets")


def test_a_todo_with_no_checklist_or_tags_yields_empty_tuples():
    fake = FakeThings(todos=[{"uuid": "U1", "title": "t"}])

    (todo,) = load_todos(tasks=fake.tasks, projects=fake.projects)

    assert todo.tags == () and todo.checklist == ()


@pytest.mark.live
def test_the_real_database_yields_usable_todos():
    """Opt-in: run with `uv run pytest -m live` against the real Things database."""
    todos = load_todos()

    assert todos
    assert all(todo.uuid and todo.title is not None for todo in todos)
