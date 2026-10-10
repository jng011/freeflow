#!/bin/bash
# Re-sign Free Flow.app for notarization: Sparkle's helpers first (inside out), then
# the app. A plain xcodebuild build leaves them with Sparkle's own signature,
# which Apple rejects ("not signed with a valid Developer ID certificate").
set -euo pipefail
# Signing identity, team and notary profile live in scripts/local.env (not published).
[ -f "$(dirname "$0")/local.env" ] && . "$(dirname "$0")/local.env"
APP="${1:?usage: sign-parle-app.sh /path/to/Free Flow.app}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="${PARLE_SIGN_IDENTITY:?set PARLE_SIGN_IDENTITY in scripts/local.env}"
ENTITLEMENTS="${PARLE_ENTITLEMENTS:-$REPO/FreeFlow/FreeFlow.local.entitlements}"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [ -n "${PARLE_TIMESTAMP:-}" ]; then TS="--timestamp"; else TS="--timestamp=none"; fi
sign() { codesign --force --options runtime "$TS" --sign "$IDENTITY" "$@"; }

if [ -d "$SPARKLE" ]; then
    sign "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
    sign --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
    sign "$SPARKLE/Versions/B/Autoupdate"
    sign "$SPARKLE/Versions/B/Updater.app"
    sign "$SPARKLE"
fi
sign --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict "$APP"
