# thingsync — one-way mirror from Things 3 to Apple Reminders

## Context

Things 3 holds the authoritative task list, but Apple Reminders is what's reachable
from Siri, Apple Watch, CarPlay and shared lists. There is no Things Cloud API, so any
integration has to work locally on the Mac: read the Things SQLite database, write via
EventKit.

The goal is a **one-way mirror** — Things is the source of truth, Reminders is a
reflection of it. All open to-dos are mirrored. It runs as a CLI, invoked manually.
Edits made in Reminders are not read back and will be overwritten on the next run.

The project directory `/Users/jsh/Projects/thingsync` is currently empty; this is
greenfield, including `git init`.

## Decisions taken

| Decision | Choice |
|---|---|
| Direction | One-way, Things → Reminders. Reminders is disposable output. |
| Scope | All open (incomplete, non-trashed) to-dos. |
| Trigger | Manual CLI. No launchd agent — see Permissions for why this is not merely deferred packaging. |
| Stack | Python 3.12 via `uv`/`mise`; `things.py` to read, PyObjC EventKit to write. |
| Identity | Things UUID written **in band** on each reminder; the state file is only a cache. |

## Verified facts (established by spike, 2026-08-22)

These were checked against the real libraries rather than assumed. Anything not listed
here and not cited to Apple's docs is an assumption.

| Claim | Result |
|---|---|
| `EKCalendarItem` / `EKReminder` expose a URL property | **Yes** — PyObjC: `URL`, `setURL_`, `URLString`, `setURLString_` |
| `EKReminder.parentReminder` exists | **No** — no public nesting property. A private `parentID` / `setParentID_` exists; undocumented, not for use. |
| `things.tasks()` includes checklists by default | **No** — signature is `tasks(uuid=None, include_items=False, **kwargs)` |
| `things.py` DB path can be redirected for tests | **Yes** — `THINGSDB` environment variable (`things/database.py:36,182`) |
| `things.py` opens the DB immutably | **No** — `file:{path}?mode=ro`, no `immutable` (`database.py:191`) |
| `things.py` reuses one connection | **Yes**, one connection built in `__init__`, but each query runs in its own transaction (`with self.connection:`) — so multi-query reads are **not** a single snapshot |

Still unverified, and gating (see Increment 0):

- Whether a custom `things:///` scheme survives `setURL_` → save → refetch, and an
  iCloud round-trip. **The identity model below depends on this.**
- Whether a date-only `dueDateComponents` surfaces a notification at the user's all-day
  reminder time.
- Whether the Things group container is unreadable without Full Disk Access on this
  machine (asserted in an earlier session; not re-confirmed).

## Architecture

```
thingsync/
  pyproject.toml            # uv-managed, entry point `thingsync`
  .mise.toml                # pins python + uv
  src/thingsync/
    cli.py                  # argparse: sync, doctor, rebuild-state; --dry-run, --list, --on-done, --yes
    things_source.py        # adapter over things.py -> list[ThingsTodo]
    reminders_sink.py       # adapter over EventKit -> create/update/complete/lookup/scan
    model.py                # ThingsTodo, ReminderPayload, SyncAction dataclasses
    mapping.py              # ThingsTodo -> ReminderPayload field mapping (pure)
    planner.py              # (todos, state, markers) -> [SyncAction]  (pure, the core)
    state.py                # load/save JSON state store, atomic write
  tests/
```

The two adapters are the only macOS-touching code and sit behind narrow protocols
(`TodoSource`, `ReminderSink`). `planner.py` and `mapping.py` are pure and carry the
test weight; adapters are faked in unit tests.

### Identity model — read this before the state store

Apple documents `calendarItemIdentifier` as a *local* identifier: "A full sync with the
calendar will lose this identifier." iCloud Reminders full-syncs are routine, not
exotic. It therefore cannot be the durable key.

Composed with a naive "reminder gone → user deleted it → recreate" rule, one iCloud
resync would recreate every mirrored reminder while the originals remain — and the
safety rule would then forbid ever cleaning up the orphans, because their identifiers
are exactly what was lost. Silent, permanent duplication of the whole list.

Durable identity is therefore written **in band**, on the reminder itself:

    reminder.setURL_(NSURL("things:///show?id=<things-uuid>"))

This survives resync and state-file loss, and doubles as a working deep link back into
Things. `calendarItemIdentifier` is kept in the state file only as a fast-path cache.

**Fallback if Increment 0 shows the URL does not round-trip:** a sentinel final line in
`notes` (`⟨thingsync:<uuid>⟩`). Uglier and user-visible, but equally durable. Everything
else in this plan is unchanged by that swap — only `mapping.py` and the sink's scan
differ.

Lookup order for a known to-do:

1. `calendarItemWithIdentifier:` on the cached id — synchronous, cheap.
2. On miss, scan the target list for a marker carrying this Things UUID; if found,
   refresh the cached identifier.
3. Only if both miss is the reminder genuinely absent → recreate.

Step 2 is what distinguishes "user deleted it" from "identifier rotated". Never
collapse it into step 3.

### State store

`~/.local/state/thingsync/<target-list>.json` — **one file per target list**, because
`--list` is a per-run flag and a single global file would let a `--list Scratch` run
leave mappings that a later default run applies to the wrong list.

```json
{ "version": 1,
  "target_list": "Things",
  "items": { "<things-uuid>": { "reminder_id": "<calendarItemIdentifier — cache only>",
                                "hash": "<sha256 of payload>" } } }
```

Rules:

- Written **atomically**: temp file in the same directory, then `os.replace`.
- Persisted **incrementally** as writes succeed, not once at the end. A crash partway
  through a first run must not leave created reminders unrecorded.
- A corrupt or unparseable state file is a **hard error**, never an implicit empty
  state — "corrupt → start fresh" is the mass-duplication path again. The error names
  `thingsync rebuild-state`, which reconstructs the mapping by scanning the target list
  for markers.
- If `target_list` in the file disagrees with the requested `--list`, refuse and say so.

**Safety rule, non-negotiable:** thingsync only ever touches reminders it can *prove*
are its own — either the identifier is in the state file, or the reminder carries a
thingsync marker. Hand-made reminders are never modified or deleted, even in the
target list.

### Field mapping (`mapping.py`)

| Things | Reminders |
|---|---|
| `title` | `title` |
| `notes` | `notes` body |
| `area_title` / `project_title` / `heading_title` | breadcrumb prepended to notes (`Area › Project › Heading`). Note the `_title` suffix — bare `area`/`project` are UUIDs. |
| `tags` | appended to notes as `#tag` text — EventKit has no public tag API |
| `checklist` | appended to notes as `☐ item` lines — **requires `include_items=True`** |
| `deadline` (a `'YYYY-MM-DD'` **string**) | `dueDateComponents`, date-only; parse explicitly, there is no direct handoff |
| `start_date` (When) | `startDateComponents`, date-only |
| `reminder_time` | **not mapped** in v1 — see limitations |
| `uuid` | marker: `URL` = `things:///show?id=<uuid>` |
| Inbox / Anytime / Someday | not mapped; everything lands in one list |

**Alarms:** never set `alarms`. `startDateComponents` on its own does not notify —
alarms are the notification mechanism, so the original no-alarm guard was correct and
is retained. Whether a date-only `dueDateComponents` additionally surfaces at the
user's configured all-day reminder time is unconfirmed; Increment 0 checks it, and
first runs go to a throwaway list regardless.

### Sync algorithm (`planner.py`)

Inputs: the open Things to-dos, the state, and the set of markers scanned from the
target list. The scan is passed in, so the planner stays pure and fully testable.

For each open Things to-do:

- not in state, no marker in list → **Create**
- not in state, marker found → **Adopt** (record the mapping, then continue as below)
- in state, hash changed → **Update**, via the 3-step lookup
- in state, hash unchanged, lookup resolves → no-op
- in state, hash unchanged, all three lookup steps miss → **Create**

For each state entry whose to-do is no longer open in Things (completed, cancelled,
trashed, or vanished):

- **Complete** the reminder and drop the mapping (default), or **Delete** it with
  `--on-done delete`.

If destructive actions (complete + delete) exceed a threshold, require `--yes`. A
planner bug should not be able to silently clear a list.

`--dry-run` prints the action list and writes nothing. This is how the first run should
always be done.

## Permissions — the fiddly part

macOS attributes privacy grants to the **responsible process** — your terminal, not the
script. Both grants below therefore apply to Terminal/iTerm2 and, by extension, to
everything you ever run from that terminal. Say this plainly in the README; it is a real
privilege expansion, not a footnote.

1. **Full Disk Access** for the terminal — `~/Library/Group Containers/` is TCC
   protected, so `JLMPQHK86H.com.culturedcode.ThingsMac/` is unreadable without it.
   `doctor` establishes this empirically rather than the README asserting it.
2. **Reminders access** — macOS 14+ requires
   `requestFullAccessToRemindersWithCompletion:`; `requestAccessToEntityType:completion:`
   was deprecated in macOS 14.0.

**Why there is no launchd agent, and why that is not just packaging:** if the
responsible process's `Info.plist` lacks `NSRemindersFullAccessUsageDescription`, TCC
denies **synchronously, with no prompt and no System Settings entry**. Terminals prompt
normally, so the manual CLI is fine; launchd, cron and ssh contexts are not. A scheduled
version needs a signed app bundle carrying its own usage strings. Do not plan around
this being a later flag.

`thingsync doctor`:

- Reports Reminders status via `authorizationStatusForEntityType:` — this does **not**
  prompt.
- Prints the responsible host process alongside the status, because `notDetermined` and
  `denied` each have two very different causes (not yet asked vs. host has no usage
  string; user said no vs. wrong host process). Without this, `doctor` will confidently
  misdiagnose the one failure it exists to catch.
- Probes the Things DB by **actually opening it** read-only, not by `os.access`.
  `things.py` uses `mode=ro` without `immutable`, so a WAL database also needs readable
  `-shm`/`-wal` files or a writable containing directory — "Things has been launched
  once" is not the whole precondition.
- Names the exact System Settings pane for each failure and exits non-zero.

EventKit note: prefer `calendarItemWithIdentifier:` (synchronous) for cached lookups.
Only the access request and any full-list fetch need the async completion-handler
bridge. Decide the `saveReminder:commit:error:` batching policy deliberately in
Increment 7 — `commit=False` plus one final commit is much faster on a first run but
changes crash semantics to all-or-nothing per batch, which interacts with the
incremental-persist rule above.

## Increments (TDD, one commit each)

**0. Spikes — throwaway, explicitly exempt from TDD.** Do not build on unverified
   premises. Three questions, then delete the code:
   a. Does `setURL_` with a `things:///` URL round-trip through save → refetch, and
      through an iCloud sync? Decides marker vs. notes-sentinel.
   b. Do two reminders with past date-only due dates produce notifications?
   c. Does the Things container read without Full Disk Access on this machine?

1. `git init`; uv/mise scaffold; `pytest` green with one trivial test.
2. `doctor`: permission status, host-process identity, DB-openability probe, exit codes.
   **Moved early deliberately** — this is what stops every later failure being debugged
   as a code bug.
3. `model.py` + `mapping.py`: to-do → payload — notes composition, breadcrumb from the
   `_title` fields, `'YYYY-MM-DD'` parsing, and the marker. Pure tests.
4. `state.py`: load/save/round-trip, missing file, version handling, **corrupt-file hard
   error**, and atomic write. Pure tests over `tmp_path`.
5. `planner.py`: create / adopt / update / skip / complete / recreate against fake state
   and a fake marker scan. The most test cases live here; the **adopt** path and the
   **"hash unchanged but lookup missed"** path are the ones that matter.
6. `things_source.py`: `things.py` → `ThingsTodo`. Point `THINGSDB` at a fixture database
   — the env override makes this viable without reverse-engineering the schema, and
   things.py's own repo ships a test DB to start from. Assert `include_items=True` is
   actually passed. Keep one opt-in live-DB smoke test, skipped by default.
7. `reminders_sink.py`: EventKit create/update/complete/lookup + marker scan. Document
   the `commit:` policy.
8. `cli.py`: `sync --dry-run`, then real `sync`; `rebuild-state`.
9. `README.md`: permissions setup, the terminal-wide grant caveat, usage, the "Reminders
   is disposable" contract, limitations.

## Known limitations (state these in the README)

- **Checklists** flatten into notes text. EventKit exposes no public API for nested
  reminders — verified: `EKReminder` has no `parentReminder`. A private `parentID`
  exists and is not used.
- **Tags** become notes text — EventKit has no public tag API.
- **Repeating to-dos** mirror as the single next instance, with no recurrence rule.
- **`reminder_time` is not mapped** — a Things to-do with an explicit reminder time
  loses it.
- **Reminders-side edits are lost** on the next run. By design.
- **Un-completing** a to-do in Things creates a fresh reminder; the previously completed
  one is left in place.
- A reminder the user **moves to a different list** is still updated in place, in the
  wrong list.
- Reading while Things is being actively edited can mix snapshots — tags and checklists
  are separate queries in separate transactions — which surfaces as a spurious update.
  Harmless.
- Things must have been launched at least once on this Mac for the database to exist.

## Verification

```sh
uv run pytest                                 # unit suite
uv run thingsync doctor                       # both permissions green
uv run thingsync sync --dry-run --list Scratch
uv run thingsync sync --list Scratch          # real run into a throwaway list
```

Then, by hand:

1. Open Reminders — the Scratch list matches the open Things to-dos, with correct due
   dates and notes breadcrumbs.
2. Re-run — output shows all skips, no duplicates. The idempotence check.
3. Complete a to-do in Things, re-run — the matching reminder is completed.
4. Edit a to-do's title in Things, re-run — updated in place, not duplicated.
5. Delete a mirrored reminder by hand, re-run — it is recreated.
6. Create an unrelated reminder by hand in the same list, re-run — it is untouched.
7. **Delete the state file, re-run — everything is adopted via markers, no duplicates.**
   This is the identity-model regression check and the single most important manual test.
8. **Corrupt the state file, re-run — hard error naming `rebuild-state`, nothing written.**
9. Run with `--list Scratch`, then `--list Other` — the second must start clean, never
   reuse Scratch's mappings.
