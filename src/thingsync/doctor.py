"""Establish the two permissions thingsync needs, empirically.

Both are attributed by macOS to the *responsible process* — the terminal you ran
this from, not this script — so every diagnosis names that process too. Without
it, ``notDetermined`` and ``denied`` are each ambiguous between two very
different causes, and doctor would confidently misdiagnose the one failure it
exists to catch.
"""

from __future__ import annotations

import ctypes
import sqlite3
from dataclasses import dataclass
from pathlib import Path

FULL_DISK_ACCESS_PANE = (
    "System Settings → Privacy & Security → Full Disk Access "
    "(add your terminal, then restart it — macOS binds the decision at launch)"
)
REMINDERS_PANE = "System Settings → Privacy & Security → Reminders"


@dataclass(frozen=True)
class Check:
    name: str
    ok: bool
    detail: str
    remedy: str | None = None


def probe_things_database(path: Path) -> Check:
    """Open the database the way things.py does, and actually read from it.

    ``os.access`` is not enough. things.py opens ``file:...?mode=ro`` *without*
    ``immutable``, so a WAL database also needs readable ``-shm``/``-wal``
    sidecars or a writable containing directory. Only a real query proves it.
    """
    if not path.exists():
        return Check(
            name="Things database",
            ok=False,
            detail=(
                f"no database at {path} — Things must have been launched at "
                "least once on this Mac"
            ),
            remedy="Launch Things 3 once, then re-run thingsync doctor",
        )

    try:
        connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        try:
            connection.execute("select 1 from sqlite_master limit 1").fetchall()
        finally:
            connection.close()
    except (sqlite3.Error, OSError) as error:
        return Check(
            name="Things database",
            ok=False,
            detail=f"cannot read {path}: {error}",
            remedy=FULL_DISK_ACCESS_PANE,
        )

    return Check(name="Things database", ok=True, detail=f"readable at {path}")


NOT_DETERMINED = 0
RESTRICTED = 1
DENIED = 2
FULL_ACCESS = 3
WRITE_ONLY = 4


def reminders_check(status: int, host: str) -> Check:
    """Turn an ``EKAuthorizationStatus`` into a diagnosis that names the host.

    ``notDetermined`` means either "nobody has asked yet" or "the host has no
    ``NSRemindersFullAccessUsageDescription``, so TCC denies synchronously with
    no prompt at all". ``denied`` means either "the user said no" or "the grant
    is attached to a different host". The status alone cannot tell these apart,
    which is why the host is always reported alongside it.
    """
    name = "Reminders access"

    if status == FULL_ACCESS:
        return Check(name, True, f"full access, granted to {host}")

    if status == NOT_DETERMINED:
        return Check(
            name,
            False,
            f"not determined for {host}",
            remedy=(
                f"Run `thingsync sync` from {host} to trigger the prompt. If no "
                "prompt appears, that host has no NSRemindersFullAccessUsageDescription "
                "and TCC is denying synchronously — that host is missing the "
                "NSRemindersFullAccessUsageDescription usage description, so run "
                "from a terminal instead"
            ),
        )

    if status == WRITE_ONLY:
        return Check(
            name,
            False,
            f"write-only access for {host}; thingsync must read to avoid duplicating",
            remedy=REMINDERS_PANE,
        )

    if status == RESTRICTED:
        return Check(
            name,
            False,
            f"restricted for {host} — likely a device management profile",
            remedy=REMINDERS_PANE,
        )

    return Check(
        name,
        False,
        f"denied for {host}",
        remedy=(
            f"{REMINDERS_PANE} — enable it for {host}. If {host} is not listed, "
            "the grant is attached to a different host process"
        ),
    )


class _ProcBSDInfo(ctypes.Structure):
    """``struct proc_bsdinfo`` from ``<libproc.h>``, as far as the fields we need."""

    _pack_ = 4
    _layout_ = "ms"
    _fields_ = [
        ("pbi_flags", ctypes.c_uint32),
        ("pbi_status", ctypes.c_uint32),
        ("pbi_xstatus", ctypes.c_uint32),
        ("pbi_pid", ctypes.c_uint32),
        ("pbi_ppid", ctypes.c_uint32),
        ("pbi_uid", ctypes.c_uint32),
        ("pbi_gid", ctypes.c_uint32),
        ("pbi_ruid", ctypes.c_uint32),
        ("pbi_rgid", ctypes.c_uint32),
        ("pbi_svuid", ctypes.c_uint32),
        ("pbi_svgid", ctypes.c_uint32),
        ("rfu_1", ctypes.c_uint32),
        ("pbi_comm", ctypes.c_char * 16),
        ("pbi_name", ctypes.c_char * 32),
        # proc_pidinfo rejects a short buffer, so the tail must be declared too.
        ("pbi_nfiles", ctypes.c_uint32),
        ("pbi_pgid", ctypes.c_uint32),
        ("pbi_pjobc", ctypes.c_uint32),
        ("e_tdev", ctypes.c_uint32),
        ("e_tpgid", ctypes.c_uint32),
        ("pbi_nice", ctypes.c_int32),
        ("pbi_start_tvsec", ctypes.c_uint64),
        ("pbi_start_tvusec", ctypes.c_uint64),
    ]


PROC_PIDTBSDINFO = 3


def _native_lookup(pid: int) -> tuple[int, str] | None:
    """Parent pid and process name, via libproc.

    ``proc_pidinfo`` is public C API, so this needs no subprocess and no PATH —
    which matters, because doctor has to work in exactly the constrained
    environments where a diagnosis is most needed.
    """
    try:
        libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    except OSError:
        return None

    info = _ProcBSDInfo()
    written = libproc.proc_pidinfo(
        ctypes.c_int(pid),
        ctypes.c_int(PROC_PIDTBSDINFO),
        ctypes.c_uint64(0),
        ctypes.byref(info),
        ctypes.c_int(ctypes.sizeof(info)),
    )
    if written <= 0:
        return None

    name = (info.pbi_name or info.pbi_comm).decode("utf-8", "replace")
    return int(info.pbi_ppid), name


def process_ancestry(pid: int, lookup=_native_lookup) -> list[str]:
    """Command names from ``pid`` outwards, stopping before launchd."""
    names: list[str] = []
    seen: set[int] = set()

    while pid > 1 and pid not in seen:
        seen.add(pid)
        found = lookup(pid)
        if found is None:
            break
        parent, name = found
        names.append(name)
        pid = parent

    return names


def responsible_host(ancestry: list[str], term_program: str | None = None) -> str:
    """Name the process macOS attributes privacy grants to.

    The ancestry walk cannot see past a root-owned ``login``, which every
    terminal spawns between itself and your shell — so the terminal app is
    usually absent from the visible chain. ``TERM_PROGRAM`` names it directly,
    and is the better answer whenever it is set.
    """
    if term_program:
        return term_program
    return ancestry[-1] if ancestry else "unknown"


def report(checks: list[Check]) -> tuple[list[str], int]:
    """Render the checks, and decide the exit code."""
    lines: list[str] = []

    for check in checks:
        mark = "✓" if check.ok else "✗"
        lines.append(f"{mark} {check.name}: {check.detail}")
        if not check.ok and check.remedy:
            lines.append(f"    → {check.remedy}")

    failures = [check for check in checks if not check.ok]
    if failures:
        lines.append("")
        lines.append(f"{len(failures)} of {len(checks)} checks failed.")

    return lines, 1 if failures else 0


def things_database_path() -> Path:
    """Where things.py will look, honouring its own THINGSDB override."""
    import os

    from things.database import DEFAULT_FILEPATH, ENVIRONMENT_VARIABLE_WITH_FILEPATH

    return Path(os.getenv(ENVIRONMENT_VARIABLE_WITH_FILEPATH) or DEFAULT_FILEPATH)


def reminders_authorization_status() -> int:
    """Read the current status. This never prompts."""
    import EventKit

    return EventKit.EKEventStore.authorizationStatusForEntityType_(
        EventKit.EKEntityTypeReminder
    )


def run_doctor() -> tuple[list[str], int]:
    """Gather every check against the real machine."""
    import os

    ancestry = process_ancestry(os.getpid())
    host = responsible_host(ancestry, term_program=os.getenv("TERM_PROGRAM"))
    header = [
        f"Responsible host process: {host}",
        f"  process chain: {' ← '.join(ancestry) or 'unavailable'}",
        "  (privacy grants attach to this host, and so to everything you run from it)",
        "",
    ]
    checks = [
        probe_things_database(things_database_path()),
        reminders_check(reminders_authorization_status(), host),
    ]
    lines, code = report(checks)
    return header + lines, code
