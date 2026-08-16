#!/usr/bin/env bash
#
# Builds the two distributable Waylo.app releases and packages each as .zip + .dmg:
#
#   dist/Waylo-macOS.{zip,dmg}           — WEBSITE build (freemium: free 5 / paid 25)
#   dist/Waylo-Reviewer-macOS.{zip,dmg}  — XPRIZE REVIEWER build (unlimited tasks)
#
# Both ship the clean production surface (Judge/max-accuracy ON, NO developer
# tools). The reviewer build is compiled with the JUDGE_BUILD flag, which makes
# it send a build key so the backend waives the paywall — nothing else differs.
#
# Usage:   ./build-release.sh            # builds both
#          ./build-release.sh website    # just the website build
#          ./build-release.sh reviewer   # just the reviewer build
set -euo pipefail
cd "$(dirname "$0")"

SCHEME="WayloMac"
CONFIG="Release"
OUT="dist"
mkdir -p "$OUT"

# build_channel <name> <derivedDir> <appBaseName> [extra xcodebuild settings…]
build_channel() {
  local name="$1" derived="$2" base="$3"; shift 3
  echo "▶ Building $name build ($CONFIG)…"
  xcodebuild -project WayloMac.xcodeproj -scheme "$SCHEME" -configuration "$CONFIG" \
    -derivedDataPath "$derived" "$@" clean build | tail -4

  local appPath="$derived/Build/Products/$CONFIG/$SCHEME.app"
  [ -d "$appPath" ] || { echo "✗ $name build failed: $appPath not found"; exit 1; }

  rm -rf "$OUT/$base.app"; cp -R "$appPath" "$OUT/$base.app"

  local zip="$OUT/$base-macOS.zip"
  rm -f "$zip"
  ditto -c -k --sequesterRsrc --keepParent "$OUT/$base.app" "$zip"

  local dmg="$OUT/$base-macOS.dmg"
  rm -f "$dmg"
  hdiutil create -volname "$base" -srcfolder "$OUT/$base.app" -ov -format UDZO "$dmg" >/dev/null 2>&1 \
    && echo "✓ DMG:  $dmg" || echo "⚠ DMG skipped (hdiutil busy) — use the .zip"
  echo "✓ ZIP:  $zip"
  echo
}

WHICH="${1:-both}"
if [ "$WHICH" = "both" ] || [ "$WHICH" = "website" ]; then
  build_channel "WEBSITE" "build/release" "Waylo"
fi
if [ "$WHICH" = "both" ] || [ "$WHICH" = "reviewer" ]; then
  build_channel "REVIEWER" "build/reviewer" "Waylo-Reviewer" \
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS=JUDGE_BUILD"
fi

echo "Done. Upload the .dmg (or .zip) to GitHub Releases / S3 and link it from Vercel."
echo "Self-signed build — first-time users right-click the app → Open → Open,"
echo "or run: xattr -dr com.apple.quarantine /Applications/Waylo.app"
