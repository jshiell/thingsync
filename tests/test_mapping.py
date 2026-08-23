from thingsync.mapping import marker_url, uuid_from_marker


def test_marker_url_is_a_things_deep_link():
    assert marker_url("ABC-123") == "things:///show?id=ABC-123"


def test_uuid_is_recovered_from_a_marker_url():
    assert uuid_from_marker("things:///show?id=ABC-123") == "ABC-123"


def test_a_foreign_url_carries_no_uuid():
    assert uuid_from_marker("https://example.com/") is None
    assert uuid_from_marker(None) is None


from datetime import date

from thingsync.mapping import to_payload
from thingsync.model import ThingsTodo


def test_a_bare_todo_maps_title_and_marker_and_no_dates():
    payload = to_payload(ThingsTodo(uuid="U1", title="Buy milk"))

    assert payload.title == "Buy milk"
    assert payload.url == "things:///show?id=U1"
    assert payload.notes == ""
    assert payload.due_date is None
    assert payload.start_date is None


def test_things_date_strings_parse_to_dates():
    payload = to_payload(
        ThingsTodo(uuid="U1", title="t", deadline="2026-08-25", start_date="2026-08-20")
    )

    assert payload.due_date == date(2026, 8, 25)
    assert payload.start_date == date(2026, 8, 20)


def test_breadcrumb_is_prepended_using_the_title_fields():
    todo = ThingsTodo(
        uuid="U1",
        title="t",
        notes="the body",
        area_title="Work",
        project_title="Website",
        heading_title="Launch",
    )

    assert to_payload(todo).notes == "Work › Website › Launch\n\nthe body"


def test_breadcrumb_omits_missing_levels():
    todo = ThingsTodo(uuid="U1", title="t", area_title="Work", heading_title="Launch")

    assert to_payload(todo).notes == "Work › Launch"


def test_checklist_and_tags_are_appended_as_text():
    todo = ThingsTodo(
        uuid="U1",
        title="t",
        notes="the body",
        checklist=("pack bags", "book taxi"),
        tags=("errand", "urgent"),
    )

    assert to_payload(todo).notes == (
        "the body\n\n☐ pack bags\n☐ book taxi\n\n#errand #urgent"
    )


def test_inside_a_projects_own_list_the_project_level_is_dropped():
    # The list itself already conveys the project, so repeating it in every
    # note's breadcrumb would just be noise.
    todo = ThingsTodo(
        uuid="U1",
        title="t",
        area_title="Work",
        project_title="Website",
        heading_title="Launch",
    )

    assert to_payload(todo, in_project_list=True).notes == "Work › Launch"


def test_outside_a_project_list_the_project_level_is_kept():
    todo = ThingsTodo(
        uuid="U1",
        title="t",
        area_title="Work",
        project_title="Website",
        heading_title="Launch",
    )

    assert to_payload(todo, in_project_list=False).notes == "Work › Website › Launch"


from thingsync.mapping import FALLBACK_LIST_TITLE, list_title_for_project
from thingsync.model import ThingsProject


def test_a_project_maps_onto_its_own_list_title():
    project = ThingsProject(uuid="P1", title="Website", status="incomplete")

    assert list_title_for_project(project) == "Website"


def test_fallback_list_title_is_a_stable_constant():
    assert FALLBACK_LIST_TITLE == "Things — Inbox"
