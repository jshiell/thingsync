from thingsync.model import ThingsTodo
from thingsync.planner import ActionKind, resolve, plan
from thingsync.state import StateEntry

CAL = "C1"


def todo(uuid="U1", title="Buy milk", **kw):
    return ThingsTodo(uuid=uuid, title=title, **kw)


def kinds(actions):
    return [(a.kind, a.uuid) for a in actions]


def test_an_unknown_todo_with_no_marker_is_created():
    actions = plan([todo()], {}, markers={}, live={}, calendar_for_project={None: CAL})

    assert kinds(actions) == [(ActionKind.CREATE, "U1")]
    assert actions[0].payload.title == "Buy milk"
    assert actions[0].calendar_id == CAL


def test_an_unknown_todo_that_already_has_a_marker_is_adopted_not_duplicated():
    actions = plan(
        [todo()], {}, markers={"U1": (CAL, "R1")}, live={"R1": CAL},
        calendar_for_project={None: CAL},
    )

    assert kinds(actions) == [(ActionKind.ADOPT, "U1")]
    assert actions[0].reminder_id == "R1"
    assert actions[0].calendar_id == CAL


from thingsync.mapping import to_payload


def items_for(t, reminder_id="R1", stale=False):
    digest = "stale" if stale else to_payload(t).content_hash()
    return {t.uuid: StateEntry(reminder_id=reminder_id, hash=digest)}


def test_a_known_unchanged_todo_is_skipped():
    t = todo()
    actions = plan([t], items_for(t), markers={}, live={"R1": CAL}, calendar_for_project={None: CAL})

    assert kinds(actions) == [(ActionKind.SKIP, "U1")]


def test_a_known_changed_todo_is_updated_in_place():
    t = todo()
    actions = plan(
        [t], items_for(t, stale=True), markers={}, live={"R1": CAL},
        calendar_for_project={None: CAL},
    )

    assert kinds(actions) == [(ActionKind.UPDATE, "U1")]
    assert actions[0].reminder_id == "R1"


def test_a_rotated_identifier_is_recovered_through_the_marker_not_recreated():
    t = todo()
    actions = plan(
        [t], items_for(t), markers={"U1": (CAL, "R2")}, live={},
        calendar_for_project={None: CAL},
    )

    assert kinds(actions) == [(ActionKind.ADOPT, "U1")]
    assert actions[0].reminder_id == "R2"


def test_a_genuinely_deleted_reminder_is_recreated():
    t = todo()
    actions = plan([t], items_for(t), markers={}, live={}, calendar_for_project={None: CAL})

    assert kinds(actions) == [(ActionKind.CREATE, "U1")]


def test_a_todo_no_longer_open_has_its_reminder_completed():
    gone = todo()
    actions = plan([], items_for(gone), markers={}, live={"R1": CAL}, calendar_for_project={None: CAL})

    assert kinds(actions) == [(ActionKind.COMPLETE, "U1")]
    assert actions[0].reminder_id == "R1"


def test_on_done_delete_removes_the_reminder_instead():
    gone = todo()
    actions = plan(
        [], items_for(gone), markers={}, live={"R1": CAL},
        calendar_for_project={None: CAL}, on_done="delete",
    )

    assert kinds(actions) == [(ActionKind.DELETE, "U1")]


def test_a_vanished_todo_whose_reminder_is_also_gone_only_drops_the_mapping():
    gone = todo()
    actions = plan([], items_for(gone), markers={}, live={}, calendar_for_project={None: CAL})

    assert kinds(actions) == [(ActionKind.FORGET, "U1")]
    assert actions[0].reminder_id is None


def test_an_orphaned_marker_with_no_state_entry_and_no_open_todo_produces_no_action():
    actions = plan(
        [], {}, markers={"HAND-MADE": (CAL, "R9")}, live={"R9": CAL},
        calendar_for_project={None: CAL},
    )

    assert actions == []


def test_reminders_thingsync_cannot_prove_are_its_own_are_never_touched():
    # The cached identifier R1 no longer resolves (rotated or hand-deleted),
    # and no marker recovers it. A hand-made reminder is live on the list, but
    # thingsync has no evidence it owns it, so it must never be guessed at —
    # the mapping must simply be forgotten.
    items = {"U1": StateEntry(reminder_id="R1", hash="h1")}

    actions = plan(
        [], items, markers={}, live={"R-HANDMADE": CAL},
        calendar_for_project={None: CAL}, on_done="delete",
    )

    assert kinds(actions) == [(ActionKind.FORGET, "U1")]
    assert actions[0].reminder_id is None


def test_todos_may_be_any_iterable_not_only_a_list():
    t = todo()
    actions = plan(
        iter([t]), items_for(t), markers={}, live={"R1": CAL},
        calendar_for_project={None: CAL},
    )

    assert kinds(actions) == [(ActionKind.SKIP, "U1")]


def test_a_todo_moved_between_projects_produces_one_move_not_complete_and_create():
    # A store-wide "does this identifier still resolve?" would say yes and
    # silently leave the reminder, in place, in the wrong list. Calendar-aware
    # resolution is what turns that into a MOVE instead.
    moved = todo(project_uuid="B")
    items = {"U1": StateEntry(reminder_id="R1", hash="whatever-it-was-before")}
    live = {"R1": "CAL-A"}  # still sitting in project A's old list

    actions = plan(
        [moved], items, markers={}, live=live,
        calendar_for_project={"A": "CAL-A", "B": "CAL-B"},
    )

    assert kinds(actions) == [(ActionKind.MOVE, "U1")]
    assert actions[0].reminder_id == "R1"
    assert actions[0].calendar_id == "CAL-B"
    assert actions[0].payload is not None


def test_a_moved_todo_recovered_only_by_marker_is_also_a_move_not_an_adopt():
    moved = todo(project_uuid="B")
    # No cached identifier at all; the global scan finds the marker sitting
    # in A's calendar, which still disagrees with B's target calendar.
    actions = plan(
        [moved], {}, markers={"U1": ("CAL-A", "R1")}, live={},
        calendar_for_project={"A": "CAL-A", "B": "CAL-B"},
    )

    assert kinds(actions) == [(ActionKind.MOVE, "U1")]
    assert actions[0].calendar_id == "CAL-B"


def test_resolve_prefers_the_cached_identifier_when_it_still_resolves():
    found = resolve("U1", StateEntry("R1", "h"), markers={"U1": (CAL, "R2")}, live={"R1": CAL})

    assert found == (CAL, "R1")


def test_resolve_falls_back_to_the_marker_when_the_cached_identifier_is_gone():
    found = resolve("U1", StateEntry("R1", "h"), markers={"U1": (CAL, "R2")}, live={})

    assert found == (CAL, "R2")


def test_resolve_finds_nothing_for_a_truly_unknown_todo():
    assert resolve("U1", None, markers={}, live={}) is None


from thingsync.planner import SyncAction, destructive_actions


def test_completions_and_deletions_are_the_destructive_ones():
    actions = [
        SyncAction(ActionKind.CREATE, "A"),
        SyncAction(ActionKind.UPDATE, "B"),
        SyncAction(ActionKind.SKIP, "C"),
        SyncAction(ActionKind.FORGET, "D"),
        SyncAction(ActionKind.COMPLETE, "E"),
        SyncAction(ActionKind.DELETE, "F"),
        SyncAction(ActionKind.MOVE, "G"),
    ]

    assert [a.uuid for a in destructive_actions(actions)] == ["E", "F"]
