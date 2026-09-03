# Scheduled/recurring sync — findings

Investigated setting up a recurring sync task for thingsync (2026-08-30).

## Why a plain launchd/cron job won't work

This is a documented, deliberate design decision — see README.md § "Why there
is no scheduled/launchd version" and plan.md's Trigger row ("Manual CLI. No
launchd agent — see README.md § Permissions for why.").

The reason: macOS TCC (privacy) grants for Reminders access are tied to the
*responsible process*. A terminal app (Terminal, iTerm2, Ghostty) carries the
`NSRemindersFullAccessUsageDescription` usage string in its `Info.plist`,
which is what makes TCC eligible to prompt the user and show an entry in
System Settings.

launchd, cron, and ssh contexts have no such Info.plist / usage string. If the
responsible process lacks it, TCC denies **synchronously, with no prompt and
no System Settings entry** — there's no way to grant the permission after the
fact. Full Disk Access has the same "responsible process" binding (see
README.md § Permissions) and also wouldn't survive a switch to a launchd
context.

So `uv run thingsync sync` invoked from a LaunchAgent/cron job will just fail
its Reminders (and likely FDA) checks with no recourse via System Settings.

## What would actually be needed for unattended scheduling

Per the README, "A scheduled version needs a signed app bundle carrying its
own usage strings — a different piece of work, not a flag." That implies:

- A small signed macOS app/binary wrapper with its own `Info.plist` declaring
  `NSRemindersFullAccessUsageDescription` (and whatever's needed for FDA).
- The user grants Full Disk Access + Reminders access to *that* app,
  specifically, once.
- launchd/cron then invokes that signed wrapper instead of a bare `uv run`
  from a terminal context.
- Code signing (even ad-hoc) and packaging work not yet scoped or started.

This has not been designed or estimated — it's a distinct, larger piece of
work than the existing CLI.

## Update 2026-08-31: signed-wrapper spike, falsified

Scoped and spiked the signed-app-bundle + LaunchAgent approach above (a
minimal Mach-O C shim, `fork`/`exec`/`wait` around the real
`thingsync` CLI, signed with a stable self-signed "thingsync local signer"
code-signing identity created once via Keychain Access). Full results
recorded in `plan.md`'s "Verified facts" table; summary here.

**What worked:** the signed bundle does become its own TCC responsible
process — `doctor` run inside it correctly reports itself, not its parent, as
the responsible host. The EventKit Reminders full-access grant survives both
a rebuild (different binary hash, same signing identity) and a
`launchd`-triggered launch with no terminal ancestor (`launchctl kickstart`),
with no re-prompt either way.

**What didn't: the actual blocker.** Reading the Things SQLite database (the
Full-Disk-Access-equivalent grant) does *not* silently deny the way the
original investigation above assumed — it shows a real interactive consent
prompt ("_App_ would like to access data from other apps"). But that grant,
once made via a normal Finder launch, does **not** persist across a
subsequent `launchd`-triggered launch: the prompt reappears on *every single*
`launchctl kickstart`, indefinitely, regardless of launch mode (direct exec
or `open -W -a`) or install location (ephemeral path or the real
`~/Applications`). An unattended hourly LaunchAgent would show a blocking
permission dialog every hour forever — the opposite of unattended.

This is a different failure mode than either this doc's original assumption
(silent deny, no prompt at all) or the plan's own anticipated fallback
(losing code identity entirely, falling back to `/bin/bash`'s identity):
identity attribution works correctly throughout; only *grant persistence*
under the launchd launch context fails, and only for this one TCC category.

## Where this was left

Not proceeding with the signed-wrapper + LaunchAgent approach — spiked and
falsified 2026-08-31 (see above and `plan.md`). Full CLI-from-a-terminal
remains the supported path. If unattended scheduling becomes a priority again,
the remaining options per the original plan's own escalation path are: stay
manual, or a resident login-item process living in the GUI session (a
different architecture — not a LaunchAgent invoking a background wrapper on a
timer, but something that stays running and is itself the long-lived,
already-authorized responsible process). Neither has been scoped.
