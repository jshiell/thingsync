import pytest

from thingsync.registry import Registry, RegistryEntry, load, registry_path, save


def test_a_saved_registry_round_trips(tmp_path):
    path = tmp_path / "_projects.json"
    registry = Registry(
        projects={"P1": RegistryEntry(calendar_id="C1", title="Website")}
    )

    save(path, registry)

    assert load(path) == registry


def test_a_missing_file_is_an_empty_registry(tmp_path):
    assert load(tmp_path / "absent.json") == Registry(projects={})


def test_a_registry_entry_may_have_no_cached_calendar_id_yet(tmp_path):
    path = tmp_path / "_projects.json"
    registry = Registry(projects={"P1": RegistryEntry(calendar_id=None, title="Website")})

    save(path, registry)

    assert load(path).projects["P1"].calendar_id is None


from thingsync.registry import RegistryError


def test_an_unparseable_registry_is_a_hard_error(tmp_path):
    path = tmp_path / "_projects.json"
    path.write_text("{ not json", encoding="utf-8")

    with pytest.raises(RegistryError):
        load(path)


def test_a_non_utf8_registry_is_also_a_hard_error(tmp_path):
    path = tmp_path / "_projects.json"
    path.write_bytes(b"\x80\x81\x82")

    with pytest.raises(RegistryError):
        load(path)


def test_a_structurally_wrong_registry_is_also_a_hard_error(tmp_path):
    path = tmp_path / "_projects.json"
    path.write_text('{"version": 1}', encoding="utf-8")

    with pytest.raises(RegistryError):
        load(path)


def test_an_unknown_registry_version_is_refused_rather_than_guessed(tmp_path):
    path = tmp_path / "_projects.json"
    path.write_text('{"version": 99, "projects": {}}', encoding="utf-8")

    with pytest.raises(RegistryError):
        load(path)


def test_saving_leaves_no_temporary_files_behind(tmp_path):
    path = tmp_path / "_projects.json"

    save(path, Registry(projects={"P1": RegistryEntry("C1", "Website")}))
    save(path, Registry(projects={"P2": RegistryEntry("C2", "Renovate")}))

    assert [p.name for p in tmp_path.iterdir()] == ["_projects.json"]
    assert load(path).projects == {"P2": RegistryEntry("C2", "Renovate")}


def test_registry_path_defaults_under_the_state_root(monkeypatch, tmp_path):
    monkeypatch.setenv("THINGSYNC_STATE_DIR", str(tmp_path))

    assert registry_path() == tmp_path / "_projects.json"


def test_registry_path_honours_an_explicit_root(tmp_path):
    assert registry_path(root=tmp_path) == tmp_path / "_projects.json"


from thingsync.state import legacy_state_files


def test_the_registry_file_itself_is_never_flagged_as_legacy_state(tmp_path):
    save(registry_path(root=tmp_path), Registry(projects={}))

    assert legacy_state_files(tmp_path) == []
