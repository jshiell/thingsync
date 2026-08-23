from thingsync.model import ThingsProject
from thingsync.projects_planner import CalendarInfo, ListActionKind, plan_lists
from thingsync.registry import Registry, RegistryEntry


def project(uuid="P1", title="Website", status="incomplete"):
    return ThingsProject(uuid=uuid, title=title, status=status)


def calendar(calendar_id="C1", title="Website", attested=(), foreign=False):
    return CalendarInfo(
        calendar_id=calendar_id,
        title=title,
        attested_project_uuids=frozenset(attested),
        has_foreign_reminder=foreign,
    )


def kinds(actions):
    return [(a.kind, a.project_uuid) for a in actions]


def test_a_new_project_with_no_list_and_no_cache_creates_one():
    actions = plan_lists([project()], Registry(), [])

    assert kinds(actions) == [(ListActionKind.CREATE_LIST, "P1")]
    assert actions[0].title == "Website"


def test_empty_projects_still_get_a_list():
    # Zero open to-dos is not a reason to withhold the list.
    actions = plan_lists([project()], Registry(), [])

    assert kinds(actions) == [(ListActionKind.CREATE_LIST, "P1")]


def test_an_up_to_date_project_is_kept():
    reg = Registry(projects={"P1": RegistryEntry("C1", "Website")})

    actions = plan_lists([project()], reg, [calendar()])

    assert kinds(actions) == [(ListActionKind.KEEP, "P1")]


def test_a_renamed_project_renames_its_list_in_place():
    reg = Registry(projects={"P1": RegistryEntry("C1", "Old Name")})
    cal = calendar(title="Old Name")

    actions = plan_lists([project(title="New Name")], reg, [cal])

    assert kinds(actions) == [(ListActionKind.RENAME_LIST, "P1")]
    assert actions[0].title == "New Name"
    assert actions[0].calendar_id == "C1"


def test_recovery_by_contents_when_the_cached_id_is_stale():
    # The registry's calendar id no longer resolves (e.g. after a full iCloud
    # resync), but a live calendar's markers still attest to this project.
    reg = Registry(projects={"P1": RegistryEntry("STALE-ID", "Website")})
    cal = calendar(calendar_id="NEW-ID", attested={"P1"})

    actions = plan_lists([project()], reg, [cal])

    assert kinds(actions) == [(ListActionKind.ADOPT_LIST, "P1")]
    assert actions[0].calendar_id == "NEW-ID"


def test_a_hand_made_list_already_holding_the_projects_title_is_adopted():
    # No marker, no cache: title is the only remaining signal for a
    # never-before-mirrored (or fully empty) project.
    cal = calendar(calendar_id="HAND-MADE", title="Website")

    actions = plan_lists([project()], Registry(), [cal])

    assert kinds(actions) == [(ListActionKind.ADOPT_LIST, "P1")]
    assert actions[0].calendar_id == "HAND-MADE"


def test_duplicate_project_titles_do_not_cross_adopt_the_same_list():
    cal = calendar(calendar_id="ONE-LIST", title="Errands")
    projects = [project(uuid="P1", title="Errands"), project(uuid="P2", title="Errands")]

    actions = plan_lists(projects, Registry(), [cal])

    assert kinds(actions) == [
        (ListActionKind.ADOPT_LIST, "P1"),
        (ListActionKind.CREATE_LIST, "P2"),
    ]
    assert actions[0].calendar_id == "ONE-LIST"


def test_a_closed_project_with_a_clean_list_is_deleted():
    reg = Registry(projects={"P1": RegistryEntry("C1", "Website")})
    cal = calendar(foreign=False)

    actions = plan_lists([project(status="completed")], reg, [cal])

    assert kinds(actions) == [(ListActionKind.DELETE_LIST, "P1")]


def test_a_foreign_reminder_refuses_the_deletion():
    reg = Registry(projects={"P1": RegistryEntry("C1", "Website")})
    cal = calendar(foreign=True)

    actions = plan_lists([project(status="completed")], reg, [cal])

    assert kinds(actions) == [(ListActionKind.KEEP, "P1")]
    assert actions[0].reason is not None and "foreign" in actions[0].reason.lower()


def test_a_declined_deletion_is_reported_every_run_not_just_the_first():
    reg = Registry(projects={"P1": RegistryEntry("C1", "Website")})
    cal = calendar(foreign=True)

    first_run = plan_lists([project(status="completed")], reg, [cal])
    second_run = plan_lists([project(status="completed")], reg, [cal])

    assert kinds(first_run) == kinds(second_run) == [(ListActionKind.KEEP, "P1")]
    assert first_run[0].reason == second_run[0].reason


def test_an_implausible_project_read_refuses_all_deletions():
    # The registry knows about several projects, but the read came back with
    # almost none of them at all: treat that as a bad read, not a mass
    # project closure.
    reg = Registry(
        projects={
            "P1": RegistryEntry("C1", "One"),
            "P2": RegistryEntry("C2", "Two"),
            "P3": RegistryEntry("C3", "Three"),
            "P4": RegistryEntry("C4", "Four"),
        }
    )
    calendars = [calendar(f"C{i}", f"list {i}") for i in range(1, 5)]

    actions = plan_lists([], reg, calendars)

    assert len(actions) == 4
    assert all(a.kind is ListActionKind.KEEP for a in actions)
    assert all(a.reason and "implausib" in a.reason.lower() for a in actions)


def test_a_plausible_partial_project_read_still_deletes_the_rest():
    reg = Registry(
        projects={
            "P1": RegistryEntry("C1", "One"),
            "P2": RegistryEntry("C2", "Two"),
        }
    )
    calendars = [calendar("C1", "One"), calendar("C2", "Two")]

    actions = plan_lists([project(uuid="P1", title="One")], reg, calendars)

    assert kinds(actions) == [
        (ListActionKind.KEEP, "P1"),
        (ListActionKind.DELETE_LIST, "P2"),
    ]
