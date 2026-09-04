#!/bin/sh
# Release-build, bundle, and sign thingsync, then install it.
#
# M0.2 verified (plan.md, "Verified facts", 2026-09-03) that a bare
# SwiftPM Mach-O with an Info.plist embedded only via -sectcreate does NOT
# get its own TCC identity: it inherits whatever grant its launching
# terminal already has. Row 47 of that same table (2026-08-31) confirmed
# a proper .app bundle with an on-disk Contents/Info.plist does. So the
# release artifact is a minimal .app bundle, not the bare executable --
# ~/.local/bin/thingsync is a symlink into it, kept for command-line
# ergonomics.
#
# Two things this script cannot itself verify (no TCC access in a sandboxed
# build): that the bundle's identity survives being invoked via that
# symlink rather than the bundle's own path, and that a rebuild + re-sign
# doesn't force a fresh Reminders prompt. Run `thingsync doctor` after
# install to check the first; rebuild and run it again to check the second.
set -eu

cd "$(dirname "$0")/.."

SIGNING_IDENTITY="thingsync local signer"
BUNDLE_ID="org.infernus.thingsync"
APP_DIR="${THINGSYNC_APP_DIR:-${HOME}/Applications/Thingsync.app}"
INSTALL_DIR="${THINGSYNC_INSTALL_DIR:-${HOME}/.local/bin}"

swift build -c release --disable-sandbox

rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
cp .build/release/thingsync "${APP_DIR}/Contents/MacOS/thingsync"
cp Resources/Info.plist "${APP_DIR}/Contents/Info.plist"

codesign --force \
    --sign "${SIGNING_IDENTITY}" \
    --identifier "${BUNDLE_ID}" \
    --options runtime \
    "${APP_DIR}"

mkdir -p "${INSTALL_DIR}"
ln -sf "${APP_DIR}/Contents/MacOS/thingsync" "${INSTALL_DIR}/thingsync"

echo "Installed ${APP_DIR}"
echo "Symlinked ${INSTALL_DIR}/thingsync -> it"
echo "Run \`thingsync doctor\` -- the responsible host should now be thingsync itself, not your terminal."
