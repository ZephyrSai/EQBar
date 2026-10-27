#!/bin/bash
# Builds EQBar.app with SwiftPM — no Xcode project needed (Command Line Tools are enough).
#
#   scripts/build-app.sh                 release build for this Mac's architecture, ad-hoc signed
#   UNIVERSAL=1 scripts/build-app.sh     arm64 + x86_64
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
#   BUNDLE_ID=com.example.eqbar VERSION=1.2.0 scripts/build-app.sh
#   OUTPUT=build/release scripts/build-app.sh   put EQBar.app somewhere other than build/
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="${BUNDLE_ID:-io.github.zephyrsai.eqbar}"
VERSION="${VERSION:-1.0.0}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
APP="${OUTPUT:-build}/EQBar.app"

if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  # Each triple builds into the same products folder, so keep a copy of each slice.
  BINARIES=()
  mkdir -p build/slices
  for ARCH in arm64 x86_64; do
    swift build -c release --triple "$ARCH-apple-macosx14.4"
    cp "$(swift build -c release --triple "$ARCH-apple-macosx14.4" --show-bin-path)/EQBar" "build/slices/EQBar-$ARCH"
    BINARIES+=("build/slices/EQBar-$ARCH")
  done
else
  swift build -c release
  BINARIES=("$(swift build -c release --show-bin-path)/EQBar")
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [[ ${#BINARIES[@]} -gt 1 ]]; then
  lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/EQBar"
else
  cp "${BINARIES[0]}" "$APP/Contents/MacOS/EQBar"
fi
strip -x "$APP/Contents/MacOS/EQBar"

sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/" -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" \
  Resources/Info.plist > "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

codesign --force --options runtime --timestamp=none \
  --entitlements Resources/EQBar.entitlements --sign "$SIGN_IDENTITY" "$APP"

echo "Built $APP ($(du -sh "$APP" | cut -f1), binary $(du -h "$APP/Contents/MacOS/EQBar" | cut -f1))"
