#!/bin/sh
# Release-build and sign the thingsync binary, then install it.
#
# Signing with a stable identifier is what gives thingsync its own TCC
# identity instead of inheriting whatever grant its launching terminal has --
# see plan.md's "Verified facts" for the 2026-08-31/M0.2 spikes this depends
# on. Re-signing with the same identity after a rebuild must not force a
# fresh Reminders prompt; `thingsync doctor` after install is how to confirm
# that held.
set -eu

cd "$(dirname "$0")/.."

SIGNING_IDENTITY="thingsync local signer"
BUNDLE_ID="org.infernus.thingsync"
INSTALL_DIR="${HOME}/.local/bin"

swift build -c release --disable-sandbox

codesign --force \
    --sign "${SIGNING_IDENTITY}" \
    --identifier "${BUNDLE_ID}" \
    --options runtime \
    .build/release/thingsync

mkdir -p "${INSTALL_DIR}"
cp .build/release/thingsync "${INSTALL_DIR}/thingsync"

echo "Installed to ${INSTALL_DIR}/thingsync"
echo "Run \`thingsync doctor\` to confirm permissions survived the rebuild."
