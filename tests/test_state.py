import pytest

from thingsync.state import State, StateEntry, load, save


def test_a_saved_state_round_trips(tmp_path):
    path = tmp_path / "Things.json"
    state = State(
        target_list="Things",
        items={"U1": StateEntry(reminder_id="R1", hash="h1")},
    )

    save(path, state)

    assert load(path, target_list="Things") == state


def test_a_missing_file_is_an_empty_state_for_that_list(tmp_path):
    loaded = load(tmp_path / "absent.json", target_list="Things")

    assert loaded == State(target_list="Things", items={})


from thingsync.state import StateError


def test_an_unparseable_state_file_is_a_hard_error_naming_the_repair(tmp_path):
    path = tmp_path / "Things.json"
    path.write_text("{ this is not json", encoding="utf-8")

    with pytest.raises(StateError) as raised:
        load(path, target_list="Things")

    assert "rebuild-state" in str(raised.value)


def test_a_non_utf8_state_file_is_also_a_hard_error(tmp_path):
    path = tmp_path / "Things.json"
    path.write_bytes(b"\x80\x81\x82")

    with pytest.raises(StateError) as raised:
        load(path, target_list="Things")

    assert "rebuild-state" in str(raised.value)


def test_a_structurally_wrong_state_file_is_also_a_hard_error(tmp_path):
    path = tmp_path / "Things.json"
    path.write_text('{"version": 1, "target_list": "Things"}', encoding="utf-8")

    with pytest.raises(StateError) as raised:
        load(path, target_list="Things")

    assert "rebuild-state" in str(raised.value)


def test_an_unknown_version_is_refused_rather_than_guessed(tmp_path):
    path = tmp_path / "Things.json"
    path.write_text('{"version": 99, "target_list": "Things", "items": {}}', encoding="utf-8")

    with pytest.raises(StateError):
        load(path, target_list="Things")


def test_state_for_a_different_list_is_refused(tmp_path):
    path = tmp_path / "Things.json"
    save(path, State(target_list="Scratch", items={}))

    with pytest.raises(StateError) as raised:
        load(path, target_list="Things")

    assert "Scratch" in str(raised.value) and "Things" in str(raised.value)


from thingsync.state import state_path


def test_saving_leaves_no_temporary_files_behind(tmp_path):
    path = tmp_path / "Things.json"

    save(path, State(target_list="Things", items={"U1": StateEntry("R1", "h1")}))
    save(path, State(target_list="Things", items={"U2": StateEntry("R2", "h2")}))

    assert [p.name for p in tmp_path.iterdir()] == ["Things.json"]
    assert load(path, target_list="Things").items == {"U2": StateEntry("R2", "h2")}


def test_each_target_list_gets_its_own_state_file(tmp_path):
    assert state_path("Things", root=tmp_path) != state_path("Scratch", root=tmp_path)


def test_a_list_name_cannot_escape_the_state_directory(tmp_path):
    path = state_path("../../etc/passwd", root=tmp_path)

    assert path.parent == tmp_path


def test_the_state_directory_can_be_redirected(monkeypatch, tmp_path):
    monkeypatch.setenv("THINGSYNC_STATE_DIR", str(tmp_path / "elsewhere"))

    assert state_path("Things").parent == tmp_path / "elsewhere"


def test_an_explicit_root_still_wins_over_the_environment(monkeypatch, tmp_path):
    monkeypatch.setenv("THINGSYNC_STATE_DIR", str(tmp_path / "ignored"))

    assert state_path("Things", root=tmp_path).parent == tmp_path


from thingsync.state import LegacyStateError, check_for_legacy_state, legacy_state_files


def test_an_absent_root_has_no_legacy_files(tmp_path):
    assert legacy_state_files(tmp_path / "absent") == []


def test_an_empty_root_has_no_legacy_files(tmp_path):
    assert legacy_state_files(tmp_path) == []


def test_a_top_level_state_file_is_legacy(tmp_path):
    (tmp_path / "Things.json").write_text("{}", encoding="utf-8")

    assert [p.name for p in legacy_state_files(tmp_path)] == ["Things.json"]


def test_check_for_legacy_state_passes_when_none_is_found(tmp_path):
    check_for_legacy_state(tmp_path)


def test_check_for_legacy_state_names_the_file_and_the_migration_steps(tmp_path):
    (tmp_path / "Things.json").write_text("{}", encoding="utf-8")

    with pytest.raises(LegacyStateError) as raised:
        check_for_legacy_state(tmp_path)

    message = str(raised.value)
    assert "Things.json" in message
    assert "Reminders" in message and "delete" in message.lower()


def test_the_inbox_state_file_is_never_flagged_as_legacy(tmp_path):
    (tmp_path / "inbox.json").write_text("{}", encoding="utf-8")

    assert legacy_state_files(tmp_path) == []


from thingsync.state import inbox_state_path, project_state_path


def test_project_state_lives_under_a_projects_subdirectory(tmp_path):
    assert project_state_path("P1", root=tmp_path) == tmp_path / "projects" / "P1.json"


def test_each_project_gets_its_own_state_file(tmp_path):
    assert project_state_path("P1", root=tmp_path) != project_state_path("P2", root=tmp_path)


def test_inbox_state_has_one_fixed_path(tmp_path):
    assert inbox_state_path(root=tmp_path) == tmp_path / "inbox.json"


def test_state_defaults_to_no_project_uuid():
    assert State(target_list="Things", items={}).project_uuid is None


def test_state_round_trips_its_project_uuid(tmp_path):
    path = tmp_path / "p.json"
    state = State(project_uuid="P1", target_list="Website", items={})

    save(path, state)

    assert load(path, target_list="Website", project_uuid="P1") == state


def test_a_renamed_project_does_not_raise_when_the_project_uuid_still_matches(tmp_path):
    path = tmp_path / "p.json"
    save(
        path,
        State(
            project_uuid="P1",
            target_list="Old Name",
            items={"U1": StateEntry("R1", "h1")},
        ),
    )

    loaded = load(path, target_list="New Name", project_uuid="P1")

    assert loaded.items == {"U1": StateEntry("R1", "h1")}


def test_state_for_a_different_project_is_refused_even_with_a_matching_title(tmp_path):
    path = tmp_path / "p.json"
    save(path, State(project_uuid="P1", target_list="Website", items={}))

    with pytest.raises(StateError) as raised:
        load(path, target_list="Website", project_uuid="P2")

    assert "P1" in str(raised.value) and "P2" in str(raised.value)


def test_title_only_mismatch_is_still_refused_when_no_project_uuid_is_involved(tmp_path):
    # Unchanged legacy behaviour: callers that never pass a project_uuid (and
    # state that never recorded one) still get the old title-based guard.
    path = tmp_path / "p.json"
    save(path, State(target_list="Scratch", items={}))

    with pytest.raises(StateError):
        load(path, target_list="Things")
