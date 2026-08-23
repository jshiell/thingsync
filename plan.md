# thingsync — per-project Reminders lists (plan)

## Context

Things 3 holds the authoritative task list; Apple Reminders is what's reachable from
Siri, Apple Watch, CarPlay and shared lists. thingsync is a one-way mirror,
Things → Reminders, run manually. The single-list version of this is built and
shipped — see `README.md` for the user-facing contract, permissions, usage and
limitations. This document is the design plan for the next change: mirroring each
Things **project** into its own Reminders list, instead of everything into one.

## What already exists

The sections below are a condensed recap of the shipped design, kept only because the
per-project work extends them directly. Full detail lives in the code and in
`README.md`; this isn't a duplicate of either.

### Decisions taken

| Decision | Choice |
|---|---|
| Direction | One-way, Things → Reminders. Reminders is disposable output. |
| Scope | All open (incomplete, non-trashed) to-dos. |
| Trigger | Manual CLI. No launchd agent — see `README.md` § Permissions for why. |
| Stack | Python 3.14 via `uv`/`mise`; `things.py` to read, PyObjC EventKit to write. |
| Identity | Things UUID written **in band** on each reminder; the state file is only a cache. |

### Verified facts (established by spike, 2026-08-22)

| Claim | Result |
|---|---|
| `EKCalendarItem` / `EKReminder` expose a URL property | **Yes** — PyObjC: `URL`, `setURL_`, `URLString`, `setURLString_` |
| `EKReminder.parentReminder` exists | **No** — no public nesting property. A private `parentID` / `setParentID_` exists; undocumented, not for use. |
| `things.tasks()` includes checklists by default | **No** — signature is `tasks(uuid=None, include_items=False, **kwargs)` |
| `things.py` DB path can be redirected for tests | **Yes** — `THINGSDB` environment variable (`things/database.py:36,182`) |
| `things.py` opens the DB immutably | **No** — `file:{path}?mode=ro`, no `immutable` (`database.py:191`) |
| `things.py` reuses one connection | **Yes**, one connection built in `__init__`, but each query runs in its own transaction (`with self.connection:`) — so multi-query reads are **not** a single snapshot |
| A `things:///` URL marker survives `setURL_` → save → refetch, locally | **Yes**, exercised by an opt-in live test (`tests/test_reminders_sink.py`) |
| That marker survives an actual iCloud full resync | **Unverified** — no test triggers a real resync. Load-bearing for the identity model below; still gating. |

New spikes for the per-project work append to this table (see Increment 0).

### Identity model recap

Reminder identity is not `calendarItemIdentifier` — Apple documents it as *local*, lost
on a full iCloud sync — but an in-band marker written on the reminder itself:

    reminder.setURL_(NSURL("things:///show?id=<things-uuid>"))

Lookup order for a known to-do: (1) the cached `calendarItemIdentifier`, if it still
resolves; (2) a marker scan of the target list, which is what tells "the user deleted
it" apart from "iCloud rotated the identifier" — never collapsed into (3); (3) only
then, create. The state file is a fast-path cache only: losing it is recoverable via
`thingsync rebuild-state`; corrupting it is a hard error, never a silent "start fresh."

**Safety rule, non-negotiable:** thingsync only ever touches reminders it can *prove*
are its own — cached in the state file, or carrying a marker. Hand-made reminders are
never modified or deleted, even in a list thingsync owns.

### State store recap

One state file per target list today (per project, going forward — see below), written
atomically (temp file + `os.replace`), persisted incrementally after every action (a
crash must not leave a created reminder unrecorded). Full rules and JSON shape:
`state.py`.

### Field mapping recap

| Things | Reminders |
|---|---|
| `title` | `title` |
| `notes` | `notes` body |
| `area_title` / `project_title` / `heading_title` | breadcrumb prepended to notes (`Area › Project › Heading`) |
| `tags` | appended to notes as `#tag` text |
| `checklist` | appended to notes as `☐ item` lines |
| `deadline` | `dueDateComponents`, date-only |
| `start_date` | `startDateComponents`, date-only |
| `uuid` | marker: `URL` = `things:///show?id=<uuid>` |
| Inbox / Anytime / Someday | not mapped — everything currently lands in one list |

That last row is exactly what this plan changes.

### Sync algorithm recap

`planner.plan()`: for each open to-do, resolve via cache → marker scan → create, then
choose `CREATE` / `ADOPT` (marker found, mapping was stale) / `UPDATE` (hash changed) /
`SKIP`. For each state entry no longer open, `COMPLETE` or `DELETE` (`--on-done`), or
`FORGET` if there's nothing left to act on. Destructive actions above a threshold
require `--yes`. Full detail: `planner.py`.

## Per-project Reminders lists

Every open Things project gets its own Reminders list, created and renamed
automatically. This extends the identity model and safety rule above; it does not
replace them.

### Decisions taken

| Decision | Choice |
|---|---|
| To-dos with no project (Inbox, area-only) | One fixed fallback list, e.g. `Things — Inbox`. |
| List identity across a project rename | Tracked by the project's Things UUID via a persistent registry, not by title. A rename in Things renames the list in place. |
| List identity recovery order | Scan the calendar's own contents for this project's markers first; an unambiguous last-known-title match second; `calendarIdentifier` cache is a fast-path only, never sole truth. Unqualified title-only matching was rejected — duplicate Things project titles make it unsound alone (see Known limitations). |
| A project completed/cancelled/deleted in Things | Its Reminders list is deleted — but only once a full scan (including completed reminders) proves every reminder in it is thingsync's own; any hand-made reminder found refuses the deletion and reports it, every run, until resolved by hand. |
| CLI surface | `--list` is dropped. `sync` fans out across every open project automatically. `--project NAME` restricts a run to one project's list; a to-do that has since moved out of that project is left alone rather than implicitly widening scope. Ambiguous `--project` names are a hard error, not a silent first match. |
| Empty projects | Every open project gets a list immediately, even with zero open to-dos. |
| Declined list deletion | Reported every run — a safety refusal is never silently swallowed — not silenced after the first report. |
| `--on-done` default | Unchanged (`complete`) inside project lists — no surprise behaviour change; a finished project's list still requires `--yes` to delete regardless. |

### Why list identity is a harder problem than reminder identity

`EKReminder` carries a `URL` field, which is what makes the marker in the Identity
model above possible. `EKCalendar` has no such field — no notes, no URL, nothing to
carry an in-band marker; its writable surface is `title`, `color`/`cgColor`, and a
handful of non-identity properties. `color` is technically available as a marker
channel and was considered and rejected: user-visible, users recolour lists by hand,
and ~24 bits is a poor identity space.

Consequently list identity can only be recovered from two places: the calendar's own
*contents* (does it hold reminders marked for this project's to-dos? — the same
computation `rebuild-state` already needs) or its *title*. Contents-based recovery
covers every case except a genuinely empty list, where title is the only remaining
signal — and Things permits duplicate project titles, so an unqualified title match is
unsound as a *first* resort. It is kept only as a last resort, and refuses to adopt
when more than one candidate list matches.

### New identity flows

**Global marker scan.** One `fetchRemindersMatchingPredicate_` call per run, over every
thingsync-owned calendar at once (the predicate already accepts a calendar array) — not
one scan per project. This is what makes move-detection possible at all, and it
collapses what would otherwise be N asynchronous fetches and N permission-adjacent
calls into one.

**Move.** A to-do whose marker is found in a calendar other than its current project's
list has moved in Things. The planner gains a `MOVE` action (relocate the reminder,
rewrite its payload) rather than per-list scanning, which could only see a moved-away
to-do as "gone" (→ complete the old one) and a moved-in to-do as "new" (→ create it
again) — silently, permanently duplicating it. Gated on a spike: does
`EKReminder.setCalendar_` plus save actually relocate a reminder while preserving its
`URL` marker and `calendarItemIdentifier`?

**Calendar-scoped resolution.** `resolve_live`/`_require` currently resolve a cached
`calendarItemIdentifier` store-wide. Under one list that was a documented, accepted
limitation (a hand-moved reminder is updated in the wrong list). Under many lists it
becomes the mechanism by which the mirror rots silently: the id keeps resolving, so
`UPDATE` is chosen forever instead of `MOVE`. Every resolver becomes calendar-aware.

**Project → list registry**, `~/.local/state/thingsync/_projects.json`:

```json
{ "version": 1,
  "projects": { "<project-uuid>": { "calendar_id": "<cache>", "title": "<last known>" } } }
```

**Per-project to-do state**, keyed by project UUID rather than list title — a title is
mutable, exactly the thing this project's identity philosophy already refuses to key
on for reminders. `~/.local/state/thingsync/projects/<project-uuid>.json`, plus one
fixed `inbox.json`. The existing `state.py` mismatch guard (refusing to apply one
list's state to another) is kept, but compares `project_uuid`, not the list's current
title — the prior wording would otherwise hard-error on the very first rename it
exists to support.

### Deletion — the safety-rule collision

The non-negotiable rule above ("never touch a reminder it can't prove is its own")
applies to list deletion too: removing an `EKCalendar` removes everything inside it, so
a project's list is only eligible for deletion once a scan — including completed
reminders, not just the incomplete ones `scan_markers` already covers — shows zero
reminders without a thingsync marker. Any foreign reminder refuses the deletion.

List deletion always requires `--yes`, independent of the destructive-action count: it
is a bigger blast radius than completing one reminder (it also removes thingsync's own
completed-reminder history for that project, which the default `on_done=complete`
accumulates). Deletion order is list → its state file → its registry entry, so a crash
mid-teardown leaves at worst an orphaned state file, never a live markered list with no
state for a later run to half-adopt.

An implausible deletion — the current project read returning far fewer projects than
the registry has entries for — refuses all list deletions for that run rather than
treating "project not read" as "project gone." A failed or partial Things read must
never look like a mass cancellation, the same principle the state store already applies
to a corrupt state file.

### Fan-out execution order

Every project (and the fallback bucket) is planned before anything is written: the
destructive-action gate (`DESTRUCTIVE_THRESHOLD`/`--yes`) runs once, globally, across
the whole run — gating per project would let a planner bug spread at the threshold
times the project count. Execution remains incrementally persisted per action once
gating passes, unchanged from today.

### Migration from the single-list build

Not a documentation footnote: if an old flat list and its state file are simply left in
place, the new per-project scans never look at that calendar, so every to-do is
recreated fresh in its project list while the old markered copies sit there untouched
forever — full, permanent duplication delivered by the upgrade itself. `sync` therefore
hard-errors on detecting the legacy state-file layout, naming the manual migration
steps, before any other new-model code can run. This ships as the first increment.

### Breadcrumb

`compose_notes` becomes contextual: `Area › Heading` inside a project's own list (the
list itself now conveys the project), `Area` only in the fallback list. This changes
every payload's `content_hash`, so the first sync after this change rewrites every
reminder once. Harmless, but expected.

### Increments (TDD, one commit each; every increment lands green)

0. **Spikes — throwaway, TDD-exempt.** In one commit, then delete:
   a. Does `EKReminder.setCalendar_` + save move a reminder between lists, preserving
      its `URL` marker and `calendarItemIdentifier`?
   b. Does `predicateForCompletedRemindersWithCompletionDateStarting_ending_calendars_`
      return completed reminders with `URL()` intact?
   c. Can `saveCalendar_commit_error_` rename an existing iCloud reminders list in
      place, and does `removeCalendar_commit_error_` delete one?
   d. Non-gating: does `EKCalendar.calendarIdentifier` survive a full iCloud resync?
      Record the result whenever it arrives; contents-based recovery means nothing
      downstream depends on the answer.
   Record results in the Verified facts table above.
1. **Legacy-state hard error.** `sync` refuses to run against the old single-list state
   layout, naming the migration steps. Ships first so no later commit can duplicate an
   existing user's list.
2. `model.py`: `ThingsProject(uuid, title, status)`; `project_uuid` on `ThingsTodo`.
3. `things_source.py`: `load_projects()` for every project regardless of status;
   `project_uuid` threaded through the heading path (`heading_parents` must carry the
   UUID, not just titles); fix the completed-heading hole — a to-do under a *completed*
   heading currently falls out of `heading_parents` entirely and would misroute into
   the fallback list.
4. `mapping.py`: project → list title; fallback-list constant; `compose_notes` takes an
   `in_project_list` flag.
5. `registry.py`: the project registry — load/save/round-trip, atomic write,
   corrupt-file hard error, one versioned storage layout.
6. `state.py`: re-key by `project_uuid`; fix the mismatch guard to compare UUIDs, not
   titles, so a title change does not raise.
7. `projects_planner.py`: pure. `CREATE_LIST` / `RENAME_LIST` / `ADOPT_LIST` /
   `DELETE_LIST` (guarded) / `KEEP`, given Things projects, the registry, existing
   calendar titles, and the global marker scan grouped by calendar. Tests cover:
   duplicate project titles; a hand-made list already holding the project's title;
   recovery by contents when the cached id is stale; refusal to delete with any
   foreign reminder present; refusal to delete anything when the project read looks
   implausibly empty.
8. `planner.py` + `protocols.py`: add `MOVE`; make `resolve()` calendar-aware; extend
   `ReminderSink` with `move` and calendar-scoped resolution. Test: a to-do moved
   project A → B produces exactly one `MOVE`, never `COMPLETE` + `CREATE`.
9. `reminders_sink.py` + `cli.py`, landed together (splitting `RemindersSink`'s
   calendar handling changes both call sites, so neither stands alone as green): a
   `CalendarManager` (enumerate/create/rename/delete, the global marker scan, the
   completed-reminder scan); `RemindersSink` takes a resolved calendar and gains
   `move`; `cli.py` drops `--list`/`DEFAULT_LIST`, requests access once, fans out,
   adds `--project NAME` with ambiguous-name handling, and computes the destructive
   gate globally before executing anything.
10. `rebuild-state`: project-aware. Explicitly handles orphan markers (to-do no longer
    exists in Things), an empty list unattributable to any project, and one project's
    markers found split across two lists — each named and given a defined, printed
    resolution rather than a silent pick.
11. `README.md` + `plan.md`: per-project lists, the contents-first identity model, the
    fallback list, the deletion guard and its blast radius, the migration hard error.

Given how tightly increments 8–9 depend on each other, treat them as landing together
if splitting them would leave either half unable to pass the suite on its own —
consistent with never modifying a passing test to make new code compile, and never
leaving an increment red.

### Known limitations this design accepts (state these in the README alongside the
existing ones)

- List identity recovery is weaker than reminder identity recovery: there is no
  in-band marker field on `EKCalendar`. An identifier rotation on an *empty* list, with
  no title match either, is genuinely unrecoverable and creates a second list.
- A user with 100+ open Things projects gets 100+ Reminders lists. Not addressed by
  this design; flagged as an open product question if it becomes a real problem, not
  solved speculatively here.
- `rebuild-state`'s project-grouping cannot attribute a wholly empty mirrored list back
  to a project; it is left for the operator to resolve by hand.
