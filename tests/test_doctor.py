import sqlite3

from thingsync.doctor import probe_things_database, reminders_check


def test_a_readable_database_probes_clean(tmp_path):
    db = tmp_path / "main.sqlite"
    sqlite3.connect(db).executescript("create table t (x); insert into t values (1);")

    check = probe_things_database(db)

    assert check.ok


def test_a_missing_database_is_reported_as_missing_not_as_a_permission_problem(tmp_path):
    check = probe_things_database(tmp_path / "absent.sqlite")

    assert not check.ok
    assert "launched" in check.detail.lower()


def test_an_unreadable_database_names_full_disk_access(tmp_path):
    db = tmp_path / "main.sqlite"
    sqlite3.connect(db).executescript("create table t (x);")
    db.chmod(0o000)

    check = probe_things_database(db)

    assert not check.ok
    assert "Full Disk Access" in check.remedy


def test_full_access_passes_and_still_names_the_responsible_process():
    check = reminders_check(status=3, host="iTerm2")

    assert check.ok
    assert "iTerm2" in check.detail


def test_not_determined_distinguishes_never_asked_from_a_host_that_cannot_ask():
    check = reminders_check(status=0, host="launchd")

    assert not check.ok
    assert "launchd" in check.detail
    assert "usage description" in check.remedy.lower()


def test_denied_points_at_the_reminders_pane_and_names_the_host():
    check = reminders_check(status=2, host="iTerm2")

    assert not check.ok
    assert "Reminders" in check.remedy
    assert "iTerm2" in check.detail


def test_write_only_is_not_good_enough():
    assert not reminders_check(status=4, host="iTerm2").ok


from thingsync.doctor import process_ancestry, responsible_host

CHAIN = {
    100: (99, "python3.12"),
    99: (98, "zsh"),
    98: (1, "Ghostty"),
    1: (0, "launchd"),
}


def test_the_process_chain_is_walked_up_to_launchd():
    assert process_ancestry(100, lookup=CHAIN.get) == ["python3.12", "zsh", "Ghostty"]


def test_the_responsible_host_is_the_outermost_app_not_the_script():
    assert responsible_host(["python3.12", "zsh", "Ghostty"]) == "Ghostty"


def test_an_unwalkable_chain_still_yields_a_usable_answer():
    assert responsible_host([]) == "unknown"


from thingsync.doctor import Check, report


def test_all_green_reports_success_and_exits_zero():
    lines, code = report([Check("A", True, "fine"), Check("B", True, "fine")])

    assert code == 0
    assert all("✓" in line or "fine" in line for line in lines if line.strip())


def test_any_failure_exits_non_zero_and_prints_its_remedy():
    lines, code = report(
        [Check("A", True, "fine"), Check("B", False, "broken", remedy="do the thing")]
    )

    assert code != 0
    assert any("do the thing" in line for line in lines)


def test_the_terminal_app_is_preferred_over_the_visible_chain():
    # The chain truncates at a root-owned `login`, so the terminal app that
    # actually owns the grant is usually not visible in the ancestry at all.
    assert responsible_host(["python3.12", "zsh"], term_program="ghostty") == "ghostty"


def test_the_chain_is_the_fallback_when_the_terminal_is_unnamed():
    assert responsible_host(["python3.12", "zsh"], term_program=None) == "zsh"
    assert responsible_host(["python3.12", "zsh"], term_program="") == "zsh"
