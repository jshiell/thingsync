#!/bin/sh
# Release-build and sign the thingsync binary, then install it.
#
# Signing with a stable identifier means a rebuild doesn't need a fresh
# Reminders prompt (verified live 2026-08-31, plan.md row 48). It does
# *not* give thingsync its own TCC identity separate from the terminal
# it's run from: an .app-bundle build was tried and verified live
# 2026-09-04 (plan.md) to make no difference for a plain shell exec --
# that separation only happens via `launchd` or `open`/LaunchServices,
# neither of which apply to typed-at-a-prompt CLI use. So this stays a
# bare signed binary rather than a bundle; `doctor`'s reported host will
# still name your terminal, and that's expected.
set -eu

cd "$(dirname "$0")/.."

SIGNING_IDENTITY="thingsync local signer"
BUNDLE_ID="org.infernus.thingsync"
INSTALL_DIR="${THINGSYNC_INSTALL_DIR:-${HOME}/.local/bin}"

swift build -c release --disable-sandbox

codesign --force \
    --sign "${SIGNING_IDENTITY}" \
    --identifier "${BUNDLE_ID}" \
    --options runtime \
    .build/release/thingsync

mkdir -p "${INSTALL_DIR}"
# rm first, not just cp: a stale symlink here (e.g. from the abandoned
# .app-bundle packaging attempt) would make cp write through it to a
# target whose directory no longer exists, failing with a confusing
# "No such file or directory".
rm -f "${INSTALL_DIR}/thingsync"
cp .build/release/thingsync "${INSTALL_DIR}/thingsync"

echo "Installed to ${INSTALL_DIR}/thingsync"
echo "Run \`thingsync doctor\` to confirm permissions survived the rebuild."
