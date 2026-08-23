# thingsync — design notes

## Context

Things 3 holds the authoritative task list; Apple Reminders is what's reachable from
Siri, Apple Watch, CarPlay and shared lists. thingsync is a one-way mirror,
Things → Reminders, run manually. Both the single-list build and the per-project
build described below are shipped — see `README.md` for the user-facing contract,
permissions, usage and limitations. This document is a condensed design recap, kept
only for the reasoning that doesn't belong in either the code or the README.

## What's shipped

### Decisions taken

| Decision | Choice |
|---|---|
| Direction | One-way, Things → Reminders. Reminders is disposable output. |
| Scope | All open (incomplete, non-trashed) to-dos. |
| Trigger | Manual CLI. No launchd agent — see `README.md` § Permissions for why. |
| Stack | Python 3.14 via `uv`/`mise`; `things.py` to read, PyObjC EventKit to write. |
| Identity (reminder) | Things UUID written **in band** on each reminder; the state file is only a cache. |
| Identity (list) | Tracked by the project's Things UUID via a persistent registry, not by title. A rename in Things renames the list in place. |
| List identity recovery order | Scan the calendar's own contents for this project's markers first; an unambiguous last-known-title match second; `calendarIdentifier` cache is a fast-path only, never sole truth. |
| To-dos with no project | One fixed fallback list, `Things — Inbox`. |
| A project completed/cancelled/deleted in Things | Its Reminders list is deleted — but only once a full scan (including completed reminders) proves every reminder in it is thingsync's own; any hand-made reminder found refuses the deletion and reports it, every run, until resolved by hand. |
| CLI surface | `sync` fans out across every open project automatically. `--project NAME` restricts a run to one project's list; a to-do that has since moved out of that project is left alone rather than implicitly widening scope. Ambiguous `--project` names are a hard error. |
| Empty projects | Every open project gets a list immediately, even with zero open to-dos. |
| List deletion gate | Always requires `--yes`, independent of the destructive-action count — bigger blast radius than completing one reminder. |

### Verified facts

| Claim | Result |
|---|---|
| `EKCalendarItem` / `EKReminder` expose a URL property | **Yes** — PyObjC: `URL`, `setURL_`, `URLString`, `setURLString_` |
| `EKReminder.parentReminder` exists | **No** — no public nesting property. A private `parentID` / `setParentID_` exists; undocumented, not for use. |
| `things.tasks()` includes checklists by default | **No** — signature is `tasks(uuid=None, include_items=False, **kwargs)` |
| `things.py` DB path can be redirected for tests | **Yes** — `THINGSDB` environment variable (`things/database.py:36,182`) |
| `things.py` opens the DB immutably | **No** — `file:{path}?mode=ro`, no `immutable` (`database.py:191`) |
| `things.py` reuses one connection | **Yes**, one connection built in `__init__`, but each query runs in its own transaction (`with self.connection:`) — so multi-query reads are **not** a single snapshot |
| A `things:///` URL marker survives `setURL_` → save → refetch, locally | **Yes**, exercised by an opt-in live test (`tests/test_reminders_sink.py`) |
| That marker survives an actual iCloud full resync | **Unverified** — no test triggers a real resync. Load-bearing for the identity model; still gating. |
| `EKReminder.setCalendar_` + save moves a reminder, preserving `URL` and `calendarItemIdentifier` | **Yes** — verified live 2026-08-23 |
| `predicateForCompletedRemindersWithCompletionDateStarting_ending_calendars_` returns completed reminders with `URL()` intact | **Yes** — verified live 2026-08-23 |
| `saveCalendar_commit_error_` can rename an existing iCloud list in place; `removeCalendar_commit_error_` deletes one | **Yes** — verified live 2026-08-23 |
| `EKCalendar.calendarIdentifier` survives a full iCloud resync | **Unverified** (non-gating) — contents-based recovery means nothing downstream depends on the answer |

### Why list identity is a harder problem than reminder identity

`EKReminder` carries a `URL` field, which is what makes the in-band marker possible.
`EKCalendar` has no such field — no notes, no URL, nothing to carry a marker; its
writable surface is `title`, `color`/`cgColor`, and a handful of non-identity
properties. `color` was considered and rejected as a marker channel: user-visible,
users recolour lists by hand, and ~24 bits is a poor identity space. Consequently list
identity can only be recovered from the calendar's own *contents* or its *title* — see
`README.md` § "List identity is weaker than reminder identity" for the recovery order
and its trade-offs.

### Known limitations this design accepts

- List identity recovery is weaker than reminder identity recovery: there is no
  in-band marker field on `EKCalendar`. An identifier rotation on an *empty* list, with
  no title match either, is genuinely unrecoverable and creates a second list.
- A user with 100+ open Things projects gets 100+ Reminders lists. Not addressed by
  this design; flagged as an open product question if it becomes a real problem, not
  solved speculatively here.
- `rebuild-state`'s project-grouping cannot attribute a wholly empty mirrored list back
  to a project; it is left for the operator to resolve by hand.
