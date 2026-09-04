# thingsync

A one-way mirror from **Things 3** into **Apple Reminders**, so your to-dos are
reachable from Siri, Apple Watch, CarPlay and shared lists.

Things is the source of truth. Reminders is a reflection of it.

## The contract: Reminders is disposable output

This is worth understanding before you run it.

- Every open Things **project** gets its own Reminders list, named to match —
  created automatically, renamed automatically if you rename the project in
  Things. To-dos with no project (Inbox, or sitting directly in an area) land
  in one fixed fallback list, `Things — Inbox`.
- **Edits you make in Reminders are never read back, and are overwritten on the
  next run.** Rename a mirrored reminder and the next sync renames it back;
  drag one into a different Reminders list and the next sync moves it back.
- A project's list is safe to delete entirely. A later sync rebuilds it.
- When a project is completed, cancelled or deleted in Things, its Reminders
  list is deleted too — but only once thingsync can prove every reminder in it
  is its own (see "Deleting a project's list" below).
- Reminders you created by hand in any thingsync-owned list are **never**
  touched. thingsync only ever modifies reminders — and lists — it can prove
  are its own.

## Install

Requires macOS 14+ and Things 3 (launched at least once, so its database exists).

```sh
./scripts/build-and-sign.sh   # builds, code-signs, and installs to ~/.local/bin/thingsync
```

Needs a self-signed code-signing identity named `thingsync local signer` in
your keychain (Keychain Access → Certificate Assistant → Create a Certificate
→ type "Code Signing" → "Let me override defaults" so it's marked trusted for
code signing — created once, see `scheduled-task-work.md`). Signing with a
stable identity means a later rebuild doesn't force a fresh Reminders prompt.
It does *not* give thingsync its own TCC identity separate from the terminal
you run it from — see Permissions below.

## Permissions

thingsync needs two grants, and **both attach to your terminal, not to
thingsync**. macOS assigns privacy grants to the *responsible process*, which is
the app that launched the script.

> **This is a real privilege expansion, not a footnote.** Granting Full Disk
> Access to Ghostty/iTerm2/Terminal grants it to *everything you ever run from
> that terminal*, not just this tool. Decide whether you are comfortable with
> that before proceeding. Using a separate terminal app solely for thingsync is
> a reasonable way to contain it.

1. **Full Disk Access** — `~/Library/Group Containers/` is TCC protected, so the
   Things database is unreadable without it.
   System Settings → Privacy & Security → Full Disk Access → add your terminal.
   **Then restart the terminal**: macOS binds the decision when a process starts,
   so a running terminal keeps its old answer.

2. **Reminders access** — granted by prompt the first time you run `sync`.

Check both at any time:

```sh
thingsync doctor
```

`doctor` reports each grant, names the responsible host process alongside it, and
proves the database is readable by actually opening it. It exits non-zero if
anything is wrong. The host process matters because the failure states are
ambiguous without it — `notDetermined` means either "nothing has asked yet" *or*
"this host cannot ask"; `denied` means either "you said no" *or* "the grant is on
a different app".

## Usage

Always do the first run dry:

```sh
thingsync sync --dry-run   # print the plan for every project, write nothing
thingsync sync             # do it — creates one list per open project
```

| Flag | Effect |
|---|---|
| `--project NAME` | Restrict this run to one project's list, by title. A to-do that has since moved out of that project is left alone rather than implicitly widening scope. An ambiguous name (two projects with the same title) is a hard error, not a silent first match. |
| `--dry-run` | Print the plan and write nothing at all — not even a new list. |
| `--on-done delete` | Delete finished reminders instead of completing them. |
| `--yes` | Authorise completing/deleting more than 10 reminders, **or deleting any list at all** — list deletion always needs it, regardless of count. |

Other commands:

```sh
thingsync doctor          # check permissions
thingsync rebuild-state   # reconstruct the registry and every state file from Reminders
```

## How identity survives

Apple documents `calendarItemIdentifier` as *local*: "A full sync with the
calendar will lose this identifier." iCloud Reminders full-syncs are routine.

If that identifier were the key, one resync plus a naive "reminder gone → user
deleted it → recreate" rule would duplicate your entire list, permanently.

So durable identity is written **in band**, on the reminder itself:

```
reminder.URL = things:///show?id=<things-uuid>
```

This survives state-file loss by construction — the marker is what `rebuild-state`
scans for — and doubles as a working deep link back into Things — tap it and Things
opens the to-do. State lives under `~/.local/state/thingsync/` (set
`THINGSYNC_STATE_DIR` to move it) and is only ever a fast-path cache:
`projects/<project-uuid>.json` per project, `inbox.json` for the fallback list,
and `_projects.json` — the registry mapping each project UUID to the Reminders
list currently mirroring it.

**Whether the marker itself survives an actual iCloud full resync is unverified.**
The design assumes it does — that's the whole reason `calendarItemIdentifier` (which
Apple documents as local and lost on a full sync) isn't the key — but no test here
triggers a real full resync to confirm the `URL` field survives one. What is verified,
by an opt-in live test, is the local path: `setURL_` → save → scan-and-recover. Treat
the resync claim as a design assumption, not a confirmed fact, until it's checked
against a real resync (see `plan.md`'s "Verified facts" table).

Consequences worth knowing:

- **Deleting the state file is safe.** The next run adopts every reminder via its
  marker. No duplicates.
- **Corrupting the state file is a hard error**, never a silent "start fresh" —
  that is the duplication path again. Run `thingsync rebuild-state`.
- Each project gets its own state file, keyed by the project's UUID rather
  than its title, so renaming a project in Things never trips a "wrong list"
  guard the way a title-keyed file would.

## List identity is weaker than reminder identity

`EKReminder` has a `URL` field to carry the marker above. `EKCalendar` — a
Reminders list — has no such field: no notes, no URL, nothing writable that
isn't user-visible. So a project's list can't carry an in-band marker at all,
and its identity has to be recovered a different way:

1. **Contents first.** Does a list's *contents* carry markers for this
   project's to-dos? This is the same scan `rebuild-state` already needs, so
   it costs nothing extra.
2. **Title, only as a last resort**, and only when a list is completely empty
   of markers — there is nothing else left to go on. Things allows two
   projects to share a title, so this step refuses to guess when more than one
   existing list matches.
3. **The cached calendar ID** (in `_projects.json`) is a fast path only, the
   same role the cached reminder ID plays above — never trusted on its own.

### Deleting a project's list

When a project closes (completed, cancelled, or gone from Things entirely),
thingsync will delete its Reminders list — but removing a calendar removes
everything inside it, including completed reminders, so the safety rule above
applies to lists too: deletion only proceeds once a full scan (completed
reminders included, not just the open ones a normal sync scans) shows every
reminder in the list is thingsync's own. Any reminder it can't prove ownership
of refuses the deletion, and that refusal is printed **every run** until you
resolve it by hand — never silenced after the first time you saw it. List
deletion also always requires `--yes`, independent of the usual
completion/deletion threshold: it's a bigger blast radius than completing one
reminder, since it also erases that project's completed-reminder history.

## Migrating from the single-list version

If you used the flat single-list version of thingsync before, `sync` will
refuse to run and name the manual migration steps the first time you run it
after upgrading: delete the old list by hand, delete its old state file, then
re-run `sync` to build fresh per-project lists. This check exists so the
upgrade itself can't silently duplicate your entire list — the old, now
unwatched state file would otherwise sit there forever while every to-do got
mirrored again into a brand new list.

## Why there is no scheduled/launchd version

Not packaging laziness. If the responsible process's `Info.plist` has no
`NSRemindersFullAccessUsageDescription`, TCC denies **synchronously, with no
prompt and no System Settings entry**. Terminals carry the necessary usage
strings; launchd, cron and ssh contexts do not. A scheduled version needs a
signed app bundle carrying its own usage strings — a different piece of work, not
a flag.

## Limitations

- **Checklists** flatten into notes text as `☐ item` lines. EventKit exposes no
  public API for nested reminders — `EKReminder` has no `parentReminder`. (A
  private `parentID` exists; it is deliberately not used.) Completed checklist
  items are omitted rather than shown as outstanding.
- **Tags** become `#tag` text in the notes. EventKit has no public tag API.
- **Breadcrumbs** are reconstructed. things.py sets `heading_title` *or*
  `project_title` on a to-do, never both, and never sets `area_title` on a to-do
  owned by a project — so thingsync resolves heading → project → area itself to
  produce `Area › Project › Heading`.
- **Repeating to-dos** mirror as the single next instance, with no recurrence rule.
- **`reminder_time` is not mapped.** A to-do with an explicit reminder time loses
  it. No alarms are ever set — one alarm per mirrored to-do would be an avalanche.
- **Reminders-side edits are lost** on the next run. By design — including a
  reminder you drag into a different Reminders list by hand: the next sync
  moves it back to the list its Things to-do actually belongs in.
- **Un-completing** a to-do in Things creates a fresh reminder; the previously
  completed one is left in place.
- Reading while Things is being actively edited can mix snapshots — tags and
  checklists are separate queries in separate transactions — which surfaces as a
  spurious update. Harmless.
- Things must have been launched at least once on this Mac.
- **List identity recovery is weaker than reminder identity recovery** (see
  above): an identifier rotation on a list that is also completely empty, with
  no title match either, is genuinely unrecoverable and creates a second list.
- **A user with 100+ open Things projects gets 100+ Reminders lists.** Not
  addressed here — flagged as an open product question if it becomes a real
  problem in practice, not solved speculatively.
- **`rebuild-state` can't attribute a wholly empty, unmarked list back to a
  project** by contents; if its title doesn't match one either, it's reported
  and left for you to resolve by hand.

## Development

```sh
swift build -c release && swift test   # the verify gate; see AGENTS.md
swift test --disable-sandbox           # under nono or another nested sandbox

THINGSYNC_LIVE=1 swift test --filter ThingsyncAdaptersTests   # opt-in, touches the real Things DB and Reminders
```

`Planner.swift`, `ProjectsPlanner.swift`, `Mapping.swift`, `State.swift` and
`Registry.swift` (all in `Sources/ThingsyncCore`) are pure and carry the test
weight. `Sources/ThingsyncAdapters` holds the only two things that touch the
OS: `ThingsDatabase.swift` (a direct SQLite reader, reverse-engineered from
`things.py`'s own schema and queries — see `plan.md`'s M5 section) and
`EventKitRemindersStore.swift`, which splits into `EventKitCalendarManager`
(enumerate/create/rename/delete lists, and scan their contents) and
`EventKitRemindersStore` (create/update/move/complete/delete one reminder,
given an already-resolved calendar).

Writes commit one at a time (`commit: true`) rather than batching. Batching is
faster on a first run but makes a batch all-or-nothing, which contradicts the
rule that state is persisted incrementally as each write succeeds.

thingsync was originally written in Python and ported to Swift for
distribution (no `mise`/`uv`/venv setup) and to remove the main practical
obstacle to a future resident-process background agent (see `plan.md` for
the full rationale, and why that's not the same as solving it). The port was
a strict one-to-one translation with no behaviour changes; `plan.md` has the
full milestone-by-milestone record, including the empirically-verified
platform facts it depends on.
