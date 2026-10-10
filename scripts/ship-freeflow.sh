#!/bin/bash
# Update the local Free Flow in place: build into a staging folder, smoke-test the
# new build, then quit the running copy, swap it in and relaunch. Permissions survive
# because the bundle id and Developer ID signature never change.
set -uo pipefail
# Signing identity, team and notary profile live in scripts/local.env (not published).
[ -f "$(dirname "$0")/local.env" ] && . "$(dirname "$0")/local.env"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="$REPO/.local-build/stage"
LIVE="$HOME/Applications/Free Flow.app"
BIN="Contents/MacOS/Free Flow"

rm -rf "$STAGE"; mkdir -p "$STAGE"
PARLE_OUT_DIR="$STAGE" "$REPO/scripts/build-freeflow.sh" | grep -vE 'replacing existing signature' || { echo "BUILD FAILED"; exit 1; }
NEW="$STAGE/Free Flow.app"
[ -d "$NEW" ] || { echo "BUILD FAILED: no app"; exit 1; }

# PARLE_TIMESTAMP=1: notarize + staple the app and a DMG for friends before installing.
if [ -n "${PARLE_TIMESTAMP:-}" ]; then
    VER="$(defaults read "$NEW/Contents/Info" CFBundleShortVersionString)"
    DIST="$REPO/.local-build/dist/$VER"; rm -rf "$DIST"; mkdir -p "$DIST/dmg"
    ditto "$NEW" "$DIST/dmg/Free Flow.app"; ln -s /Applications "$DIST/dmg/Applications"
    DMG="$DIST/Free-Flow-$VER.dmg"
    hdiutil create -quiet -volname "Free Flow" -srcfolder "$DIST/dmg" -fs HFS+ -format UDZO -ov "$DMG" || { echo "DMG FAILED"; exit 1; }
    codesign --force --timestamp --sign "${PARLE_SIGN_IDENTITY:?set PARLE_SIGN_IDENTITY in scripts/local.env}" "$DMG"
    xcrun notarytool submit "$DMG" --keychain-profile "${PARLE_NOTARY_PROFILE:-parle-notary}" --wait > "$DIST/notary.log" 2>&1
    grep -q "status: Accepted" "$DIST/notary.log" || { echo "NOTARIZATION FAILED: $DIST/notary.log"; tail -5 "$DIST/notary.log"; exit 1; }
    xcrun stapler staple "$DMG" >/dev/null && xcrun stapler staple "$NEW" >/dev/null || { echo "STAPLE FAILED"; exit 1; }
    spctl -a -t open --context context:primary-signature "$DMG" && spctl -a -t exec "$NEW" && echo "NOTARIZED -> $DMG"
    rm -rf "$DIST/dmg"
fi

# Optional one-off step right before the swap (e.g. a data migration).
[ -n "${PRE_SWAP_CMD:-}" ] && bash -c "$PRE_SWAP_CMD"

# Quit the running copy first (only ours, never /Applications/Free Flow.app).
pkill -f "$LIVE/$BIN" 2>/dev/null; sleep 1; pkill -9 -f "$LIVE/$BIN" 2>/dev/null

# Smoke test the new build in place of the old one; roll back if it dies.
BACKUP="$REPO/.local-build/previous.app"
rm -rf "$BACKUP"; [ -d "$LIVE" ] && mv "$LIVE" "$BACKUP"
ditto "$NEW" "$LIVE"
open "$LIVE"; sleep 10
if pgrep -f "$LIVE/$BIN" >/dev/null; then
    echo "UPDATED and running: $(defaults read "$LIVE/Contents/Info" CFBundleShortVersionString) ($(defaults read "$LIVE/Contents/Info" CFBundleVersion))"
    # Every shipped build is committed and pushed (private repo).
    VER_LINE="$(defaults read "$LIVE/Contents/Info" CFBundleShortVersionString) ($(defaults read "$LIVE/Contents/Info" CFBundleVersion))"
    cd "$REPO" && git add -A && { git diff --cached --quiet || git commit -qm "Free Flow $VER_LINE${SHIP_NOTES:+: $SHIP_NOTES}"; } \
        && git push -q && echo "PUSHED $(git rev-parse --short HEAD)"
    rm -rf "$STAGE"
else
    echo "NEW BUILD CRASHED ON LAUNCH: rolling back"
    rm -rf "$LIVE"; [ -d "$BACKUP" ] && mv "$BACKUP" "$LIVE" && open "$LIVE"
    exit 1
fi
