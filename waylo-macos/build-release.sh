#!/usr/bin/env bash
#
# Builds a distributable Waylo.app (Release) and packages it as a .zip and a
# .dmg you can upload to GitHub Releases / S3 and link from your Vercel page.
#
# Usage:   ./build-release.sh
# Output:  dist/Waylo-macOS.zip   and   dist/Waylo-macOS.dmg
#
set -euo pipefail
cd "$(dirname "$0")"

SCHEME="WayloMac"
CONFIG="Release"
DERIVED="build/release"
APP_NAME="Waylo"
OUT="dist"

echo "▶ Building $SCHEME ($CONFIG)…"
xcodebuild -project WayloMac.xcodeproj -scheme "$SCHEME" -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" clean build | tail -6

APP_PATH="$DERIVED/Build/Products/$CONFIG/$SCHEME.app"
[ -d "$APP_PATH" ] || { echo "✗ Build failed: $APP_PATH not found"; exit 1; }

mkdir -p "$OUT"
rm -rf "$OUT/$APP_NAME.app"
cp -R "$APP_PATH" "$OUT/$APP_NAME.app"

# Zip (ditto preserves the code signature and macOS metadata).
ZIP="$OUT/$APP_NAME-macOS.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$OUT/$APP_NAME.app" "$ZIP"

# DMG (nicer for a download button). Falls back silently if hdiutil is busy.
DMG="$OUT/$APP_NAME-macOS.dmg"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$OUT/$APP_NAME.app" -ov -format UDZO "$DMG" >/dev/null 2>&1 \
  && echo "✓ DMG:  $DMG" || echo "⚠ DMG step skipped (hdiutil failed) — use the .zip"

echo "✓ App:  $OUT/$APP_NAME.app"
echo "✓ ZIP:  $ZIP"
echo
echo "Next: upload the .zip (or .dmg) to GitHub Releases, copy the asset URL,"
echo "and use it as the download link on your Vercel landing page."
echo
echo "Note: this build is self-signed. First-time users must remove the"
echo "quarantine flag after downloading:"
echo "    xattr -dr com.apple.quarantine /Applications/Waylo.app"
echo "or right-click the app → Open → Open."
