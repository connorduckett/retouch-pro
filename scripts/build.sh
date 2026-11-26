#!/bin/bash
# Builds "Retouch Pro.app" (Apple Silicon + Intel) into dist/ and zips it for sharing.
# Usage: ./scripts/build.sh [version]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-1.0.0}"
BUILD="$(date +%Y%m%d%H%M)"
APP="dist/Retouch Pro.app"

# Command Line Tools ship a newer SDK whose SwiftUI macros need full Xcode; prefer the 26.x SDK when present.
if [[ -z "${SDKROOT:-}" ]]; then
  for sdk in /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk; do
    if [[ -d "$sdk" ]] && ! xcode-select -p | grep -q Xcode.app; then export SDKROOT="$sdk"; break; fi
  done
fi

echo "▸ Building Apple Silicon…"
swift build -c release --triple arm64-apple-macosx13.0 --scratch-path .build/arm64
echo "▸ Building Intel…"
swift build -c release --triple x86_64-apple-macosx13.0 --scratch-path .build/x86_64

echo "▸ Assembling app bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create \
  .build/arm64/release/RetouchPro \
  .build/x86_64/release/RetouchPro \
  -output "$APP/Contents/MacOS/RetouchPro"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"

echo "▸ Drawing icon…"
ICONSET="$(mktemp -d)/AppIcon.iconset"
swift scripts/make_icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "▸ Signing (ad-hoc)…"
codesign --force --deep --sign - "$APP"

echo "▸ Zipping…"
rm -f dist/RetouchPro.zip
ditto -c -k --sequesterRsrc --keepParent "$APP" dist/RetouchPro.zip

echo "✓ Built $APP ($VERSION) and dist/RetouchPro.zip"
