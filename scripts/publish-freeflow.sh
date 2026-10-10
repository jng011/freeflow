#!/bin/bash
# Publish the notarized build to GitHub (repo jng011/freeflow) with a Sparkle appcast.
# Run after `PARLE_TIMESTAMP=1 PARLE_BUILD=<n> scripts/ship-freeflow.sh` installed it.
#   scripts/publish-freeflow.sh "<release notes>"
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
GH_REPO="${FREEFLOW_GH_REPO:-jng011/freeflow}"
APP="$HOME/Applications/Free Flow.app"
NOTES="${1:?release notes}"
VERSION=$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)
BUILD=$(defaults read "$APP/Contents/Info.plist" CFBundleVersion)
DIST="$REPO/.local-build/dist/$VERSION"
DMG="$DIST/Free-Flow-$VERSION.dmg"
[ -f "$DMG" ] || { echo "No notarized DMG at $DMG"; exit 1; }
xcrun stapler validate "$APP" >/dev/null || { echo "Installed app is not stapled"; exit 1; }
SPARKLE_BIN="$REPO/.local-build/SourcePackages/artifacts/sparkle/Sparkle/bin"
TAG="v$VERSION"
ZIP="$DIST/Free-Flow-$VERSION.zip"
rm -f "$ZIP"; ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
SIG_ATTRS=$("$SPARKLE_BIN/sign_update" --account parle-updates "$ZIP")
MIN_OS=$(defaults read "$APP/Contents/Info.plist" LSMinimumSystemVersion)
cat > "$DIST/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Free Flow</title>
    <item>
      <title>Free Flow $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <description><![CDATA[<p>$NOTES</p>]]></description>
      <enclosure url="https://github.com/$GH_REPO/releases/download/$TAG/Free-Flow-$VERSION.zip" type="application/octet-stream" $SIG_ATTRS />
    </item>
  </channel>
</rss>
XML
cd "${FREEFLOW_PUBLIC_DIR:-$REPO/../freeflow-public}"  # gh needs a checkout of the public repo
gh release create "$TAG" "$ZIP" "$DMG" "$DIST/appcast.xml" \
  --repo "$GH_REPO" --target main --title "Free Flow $VERSION" --notes "$NOTES" --latest
echo "Published Free Flow $VERSION ($BUILD) -> https://github.com/$GH_REPO/releases/tag/$TAG"
