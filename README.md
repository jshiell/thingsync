# thingsync

A one-way mirror from **Things 3** into **Apple Reminders**, so your to-dos are
reachable from Siri, Apple Watch, CarPlay and shared lists.

Things is the source of truth. Reminders is a reflection of it.

## The contract: Reminders is disposable output

This is worth understanding before you run it.

- Every open, non-trashed Things to-do is mirrored into one Reminders list.
- **Edits you make in Reminders are never read back, and are overwritten on the
  next run.** Rename a mirrored reminder and the next sync renames it back.
- The mirrored list is safe to delete entirely. A later sync rebuilds it.
- Reminders you created by hand in the target list are **never** touched.
  thingsync only ever modifies reminders it can prove are its own.

## Install

Requires macOS and Things 3 (launched at least once, so its database exists).

```sh
mise install          # python 3.12 + uv
uv sync
```

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
uv run thingsync doctor
```

`doctor` reports each grant, names the responsible host process alongside it, and
proves the database is readable by actually opening it. It exits non-zero if
anything is wrong. The host process matters because the failure states are
ambiguous without it — `notDetermined` means either "nothing has asked yet" *or*
"this host cannot ask"; `denied` means either "you said no" *or* "the grant is on
a different app".

## Usage

Always do the first run dry, into a throwaway list:

```sh
uv run thingsync sync --dry-run --list Scratch   # print the plan, write nothing
uv run thingsync sync --list Scratch             # do it
uv run thingsync sync                            # the default list, "Things"
```

| Flag | Effect |
|---|---|
| `--list NAME` | Target Reminders list. Default `Things`. Created on first write. |
| `--dry-run` | Print the plan and write nothing at all — not even the list. |
| `--on-done delete` | Delete finished reminders instead of completing them. |
| `--yes` | Authorise completing or deleting more than 10 reminders in one run. |

Other commands:

```sh
uv run thingsync doctor          # check permissions
uv run thingsync rebuild-state   # reconstruct the state file from the list
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

This survives resync and state-file loss, and doubles as a working deep link back
into Things — tap it and Things opens the to-do. The state file at
`~/.local/state/thingsync/<list>.json` is only a fast-path cache; set
`THINGSYNC_STATE_DIR` to move it.

Consequences worth knowing:

- **Deleting the state file is safe.** The next run adopts every reminder via its
  marker. No duplicates.
- **Corrupting the state file is a hard error**, never a silent "start fresh" —
  that is the duplication path again. Run `thingsync rebuild-state`.
- Each target list gets its own state file, so `--list Scratch` can never leave
  mappings that a later default run applies to the wrong list.

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
- **Reminders-side edits are lost** on the next run. By design.
- **Un-completing** a to-do in Things creates a fresh reminder; the previously
  completed one is left in place.
- A reminder you **move to a different list** is still updated in place, in the
  wrong list.
- Reading while Things is being actively edited can mix snapshots — tags and
  checklists are separate queries in separate transactions — which surfaces as a
  spurious update. Harmless.
- Things must have been launched at least once on this Mac.

## Development

```sh
uv run pytest            # unit suite; adapters are faked
uv run pytest -m live    # opt-in, touches the real Things DB and Reminders
```

`planner.py`, `mapping.py` and `state.py` are pure and carry the test weight.
`things_source.py` and `reminders_sink.py` are the only macOS-touching modules.

Writes commit one at a time (`commit=True`) rather than batching. Batching is
faster on a first run but makes a batch all-or-nothing, which contradicts the
rule that state is persisted incrementally as each write succeeds.
