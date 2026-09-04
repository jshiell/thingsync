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
| A signed Mach-O app bundle (fork/exec C shim, own `Info.plist`) becomes its own TCC "responsible process", distinct from its parent/launcher | **Yes** — verified live 2026-08-31 (macOS with a self-signed "thingsync local signer" code-signing identity). `thingsync doctor` run inside the bundle reports `Responsible host process: TCCSpike`, not any ancestor. |
| EventKit Reminders full-access grant persists across a rebuild (different CDHash, same stable signing identity) | **Yes** — verified live 2026-08-31, no re-prompt |
| EventKit Reminders full-access grant persists across a `launchd`-triggered launch (`launchctl kickstart`, no terminal ancestor) | **Yes** — verified live 2026-08-31, both via direct `ProgramArguments` exec and via `open -W -a` |
| Full Disk Access / Group Container read of the Things SQLite database shows an interactive consent prompt at all, for a signed bundle with its own `Info.plist` (contra the long-standing assumption that FDA never prompts and must be added by hand in System Settings) | **Yes, unexpectedly** — verified live 2026-08-31. A real modal prompt ("_App_ would like to access data from other apps") appears; once allowed, `sqlite3` reads the real Things database successfully. Neither TCCSpike nor TCCSpikeDB ever appeared in the Full Disk Access, Reminders, or Automation panes in System Settings despite functioning grants — apparent Launch Services indexing/UI quirk, not evidence the grant is missing. |
| That Full-Disk-Access-equivalent Things-database grant, once made via Finder, persists across a subsequent `launchd`-triggered launch (`launchctl kickstart`, no terminal ancestor) | **No** — verified live 2026-08-31. Falsifies the plan's Stage B / §0.9 pass criterion. The consent dialog reappears on **every** `launchctl kickstart`, not just the first — reproduced across both `ProgramArguments` direct-exec and `open -W -a` launch modes, and from both an ephemeral scratch path and the real `~/Applications` production install location. Code identity is still correctly attributed each time (dialog always names the app correctly) — only grant *persistence* across the launchd launch context fails. The Reminders grant above, tested under identical launchd conditions in the same process, persisted fine — so this is specific to the Full-Disk/Group-Container TCC category, not a general launchd problem. See `scheduled-task-work.md` for the fuller writeup and what this means for unattended scheduling. |
| A **bare SwiftPM Mach-O** (no `.app` bundle — a plain executable with an `Info.plist` embedded only via a `-sectcreate __TEXT __info_plist` linker section) gets read by TCC the same way the already-proven `.app`-bundle shape does (M0.2 pass criterion) | **No** — verified live 2026-09-03. `otool`/`codesign` both confirm the plist section is present and well-formed (`codesign -dv` reports `Info.plist entries=5`), so the section itself is mechanically fine. But `EKEventStore.requestFullAccessToReminders()` returned `fullAccess` on the very first call, with no prompt — and `tccutil reset Reminders org.infernus.thingsync` immediately after reported `No such bundle identifier`, i.e. TCC never created a per-app record for this binary at all. The observed access was inherited from an ancestor process already holding a Reminders grant (the terminal hosting the session), not a grant scoped to this binary — the opposite of row 47's `.app`-bundle result, where `doctor` correctly named the bundle itself as responsible host. Conclusion: the bare-Mach-O `-sectcreate` trick does not make TCC treat the binary as its own responsible process, at least not when launched as a plain subprocess from a shell. Per the plan's own contingency, this changes only M9 packaging (the release binary must ship as a proper `.app` bundle with an on-disk `Contents/Info.plist`, as row 47 already validated) — M1–M8 are unaffected, since none of them touch signing or TCC. |
| M5.14: the Swift SQLite read layer (`loadTodos`/`loadProjects`) produces byte-identical output to `things.py`, against the user's real Things database | **Yes** — verified live 2026-09-04. `--dump-things-json` (temporary hidden flag) vs. a `things_source.load_todos()`/`load_projects()` one-liner, both normalized through `python -m json.tool --sort-keys`, diffed empty on the first real run after fixing a dump-tool bug (`JSONEncoder`'s synthesized conformance was omitting `null`-valued optional keys that Python's `dataclasses.asdict()` always includes — not a data or SQL defect). |
| M8.14: `swift run thingsync sync --dry-run` matches `uv run thingsync sync --dry-run`, sorted-line diff, against the real Things/Reminders state | **Yes** — verified live 2026-09-04, empty diff. Both M5.14 and M8.14 now pass; per the repo strategy, Python deletion (M9.5) is unblocked. |
| Packaging the release binary as a proper `.app` bundle (row 47's proven shape) gives it its own TCC identity when **launched directly from an interactive shell** — i.e. the way the CLI is actually run day to day, typed at a prompt or via a `~/.local/bin` symlink into the bundle | **No** — verified live 2026-09-04. `Thingsync.app/Contents/MacOS/thingsync`, signed with the same identity as row 47, run three ways from an interactive Ghostty/zsh session — via a `~/.local/bin` symlink, and via its own absolute `Contents/MacOS/thingsync` path directly — all report `Responsible host process: ghostty` and unprompted `full access, granted to ghostty`. `tccutil reset Reminders org.infernus.thingsync` succeeds without error (so TCC does hold *some* record for the bundle identifier now — LaunchServices registered it once it existed under `~/Applications`, unlike row 52's unregistered bare binary), but a subsequent `doctor` run shows no fresh prompt and no change, meaning that record is not what the running process is actually checked against. Reconciles with rows 47–49: those successes were all launched via `launchd` (`ProgramArguments` direct exec or `open -W -a`), never as a direct child of an already-TCC-authorized interactive shell. Conclusion: TCC's parent-inherits-child attribution for a resource the parent already holds appears to take precedence over the child's own bundle identity specifically when the launch is a plain shell `fork`/`exec` — bundling only changes attribution for `open`/LaunchServices/`launchd` launch paths, not this one. The README's planned claim that packaging "reduces the FDA/Reminders-to-everything privilege expansion" does **not** hold for thingsync's actual, primary interactive usage pattern; only for a hypothetical future `launchd`-based background agent, which is out of scope (see `scheduled-task-work.md`). |

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
