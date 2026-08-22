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
