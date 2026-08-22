from thingsync.model import ThingsTodo
from thingsync.planner import ActionKind, plan
from thingsync.state import State, StateEntry


def todo(uuid="U1", title="Buy milk", **kw):
    return ThingsTodo(uuid=uuid, title=title, **kw)


def empty_state(target_list="Things"):
    return State(target_list=target_list, items={})


def kinds(actions):
    return [(a.kind, a.uuid) for a in actions]


def test_an_unknown_todo_with_no_marker_is_created():
    actions = plan([todo()], empty_state(), markers={}, live_ids=set())

    assert kinds(actions) == [(ActionKind.CREATE, "U1")]
    assert actions[0].payload.title == "Buy milk"


def test_an_unknown_todo_that_already_has_a_marker_is_adopted_not_duplicated():
    actions = plan([todo()], empty_state(), markers={"U1": "R1"}, live_ids={"R1"})

    assert kinds(actions) == [(ActionKind.ADOPT, "U1")]
    assert actions[0].reminder_id == "R1"


from thingsync.mapping import to_payload


def state_for(t, reminder_id="R1", stale=False):
    digest = "stale" if stale else to_payload(t).content_hash()
    return State(
        target_list="Things",
        items={t.uuid: StateEntry(reminder_id=reminder_id, hash=digest)},
    )


def test_a_known_unchanged_todo_is_skipped():
    t = todo()
    actions = plan([t], state_for(t), markers={}, live_ids={"R1"})

    assert kinds(actions) == [(ActionKind.SKIP, "U1")]


def test_a_known_changed_todo_is_updated_in_place():
    t = todo()
    actions = plan([t], state_for(t, stale=True), markers={}, live_ids={"R1"})

    assert kinds(actions) == [(ActionKind.UPDATE, "U1")]
    assert actions[0].reminder_id == "R1"


def test_a_rotated_identifier_is_recovered_through_the_marker_not_recreated():
    t = todo()
    actions = plan([t], state_for(t), markers={"U1": "R2"}, live_ids=set())

    assert kinds(actions) == [(ActionKind.ADOPT, "U1")]
    assert actions[0].reminder_id == "R2"


def test_a_genuinely_deleted_reminder_is_recreated():
    t = todo()
    actions = plan([t], state_for(t), markers={}, live_ids=set())

    assert kinds(actions) == [(ActionKind.CREATE, "U1")]


def test_a_todo_no_longer_open_has_its_reminder_completed():
    gone = todo()
    actions = plan([], state_for(gone), markers={}, live_ids={"R1"})

    assert kinds(actions) == [(ActionKind.COMPLETE, "U1")]
    assert actions[0].reminder_id == "R1"


def test_on_done_delete_removes_the_reminder_instead():
    gone = todo()
    actions = plan([], state_for(gone), markers={}, live_ids={"R1"}, on_done="delete")

    assert kinds(actions) == [(ActionKind.DELETE, "U1")]


def test_a_vanished_todo_whose_reminder_is_also_gone_only_drops_the_mapping():
    gone = todo()
    actions = plan([], state_for(gone), markers={}, live_ids=set())

    assert kinds(actions) == [(ActionKind.FORGET, "U1")]
    assert actions[0].reminder_id is None


def test_reminders_thingsync_cannot_prove_are_its_own_are_never_touched():
    stranger = todo(uuid="HAND-MADE")
    actions = plan([], empty_state(), markers={"HAND-MADE": "R9"}, live_ids={"R9"})

    assert actions == []


def test_todos_may_be_any_iterable_not_only_a_list():
    t = todo()
    actions = plan(iter([t]), state_for(t), markers={}, live_ids={"R1"})

    assert kinds(actions) == [(ActionKind.SKIP, "U1")]


from thingsync.planner import SyncAction, destructive_actions


def test_completions_and_deletions_are_the_destructive_ones():
    actions = [
        SyncAction(ActionKind.CREATE, "A"),
        SyncAction(ActionKind.UPDATE, "B"),
        SyncAction(ActionKind.SKIP, "C"),
        SyncAction(ActionKind.FORGET, "D"),
        SyncAction(ActionKind.COMPLETE, "E"),
        SyncAction(ActionKind.DELETE, "F"),
    ]

    assert [a.uuid for a in destructive_actions(actions)] == ["E", "F"]
