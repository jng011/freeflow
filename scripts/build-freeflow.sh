#!/bin/bash
# Build Free Flow (local) (Release, LOCAL_BUILD) signed with Developer ID, hardened runtime,
# secure timestamp — notarization-ready. Prints only errors and the result.
set -uo pipefail
# Signing identity, team and notary profile live in scripts/local.env (not published).
[ -f "$(dirname "$0")/local.env" ] && . "$(dirname "$0")/local.env"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="${PARLE_SIGN_IDENTITY:?set PARLE_SIGN_IDENTITY in scripts/local.env}"
TEAM="${PARLE_TEAM:?set PARLE_TEAM in scripts/local.env}"
DERIVED="$REPO/.local-build"
LOG="${PARLE_BUILD_LOG:-$REPO/.local-build/parle-build.log}"
OUT_DIR="${PARLE_OUT_DIR:-$HOME/Applications}"

# PARLE_TIMESTAMP=1: secure timestamp (required for notarization; slower, needs network).
if [ -n "${PARLE_TIMESTAMP:-}" ]; then TS_FLAG="--timestamp"; else TS_FLAG="--timestamp=none"; fi
export PARLE_TIMESTAMP

mkdir -p "$DERIVED"
cd "$REPO"

xcodebuild -project FreeFlow.xcodeproj -scheme FreeFlow -configuration Release \
    -derivedDataPath "$DERIVED" \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="$TEAM" \
    PROVISIONING_PROFILE_SPECIFIER="" \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGNING_ALLOWED=YES \
    OTHER_CODE_SIGN_FLAGS="$TS_FLAG" \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    DEPLOYMENT_POSTPROCESSING=YES STRIP_INSTALLED_PRODUCT=YES \
    CODE_SIGN_ENTITLEMENTS="$REPO/FreeFlow/FreeFlow.local.entitlements" \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) LOCAL_BUILD' \
    ${PARLE_VERSION:+MARKETING_VERSION="$PARLE_VERSION"} ${PARLE_BUILD:+CURRENT_PROJECT_VERSION="$PARLE_BUILD"} \
    -skipPackagePluginValidation -skipMacroValidation \
    build >"$LOG" 2>&1
STATUS=$?

grep -E '(error|fatal error):' "$LOG" | grep -v 'MetalToolchain' | sed "s|$REPO/||" | sort -u | head -40
if [ $STATUS -ne 0 ] || ! grep -q '\*\* BUILD SUCCEEDED \*\*' "$LOG"; then
    echo "BUILD FAILED (exit $STATUS) — log: $LOG"
    exit 1
fi

APP="$DERIVED/Build/Products/Release/Free Flow.app"
[ -d "$APP" ] || { echo "BUILD SUCCEEDED but $APP missing"; exit 1; }
rm -rf "$OUT_DIR/Free Flow.app"
ditto "$APP" "$OUT_DIR/Free Flow.app"
"$REPO/scripts/sign-freeflow-app.sh" "$OUT_DIR/Free Flow.app" || { echo "Re-signing failed"; exit 1; }
echo "BUILD SUCCEEDED -> $OUT_DIR/Free Flow.app"
codesign -dvv "$OUT_DIR/Free Flow.app" 2>&1 | grep -E '^(Identifier|Authority=Developer ID Application|TeamIdentifier|Timestamp)'
codesign --verify --deep --strict "$OUT_DIR/Free Flow.app" && echo "codesign verify: OK"
