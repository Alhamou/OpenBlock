#!/bin/zsh
# Builds a Release OpenBlock.app and wraps it in a compressed DMG with an /Applications shortcut.
# Usage: scripts/make-dmg.sh [output-dir]      (default: build/)
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-build}"
xcodegen generate >/dev/null   # first, so Info.plist carries the version from project.yml
VERSION=$(sed -n 's/.*MARKETING_VERSION: "\(.*\)"/\1/p' project.yml | head -1)
DERIVED="$OUT/DerivedData-Release"
STAGE="$OUT/dmg-root"
DMG="$OUT/OpenBlock-$VERSION.dmg"

echo "▸ Building OpenBlock $VERSION (Release)"
xcodebuild -project OpenBlock.xcodeproj -scheme OpenBlock -configuration Release \
  -derivedDataPath "$DERIVED" build | grep -E "error:|BUILD" || true

APP="$DERIVED/Build/Products/Release/OpenBlock.app"
[ -d "$APP" ] || { echo "build failed: $APP missing"; exit 1; }

echo "▸ Staging"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/OpenBlock.app"
ln -s /Applications "$STAGE/Applications"

echo "▸ Creating $DMG"
hdiutil create -volname "OpenBlock $VERSION" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"

# Sign the DMG with exactly the certificate Xcode used for the app inside it.
AUTHORITY=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)
if [ -n "${AUTHORITY:-}" ]; then
  echo "▸ Signing DMG with \"$AUTHORITY\""
  codesign --sign "$AUTHORITY" --timestamp=none "$DMG" || echo "  (DMG signing failed)"
else
  echo "▸ The app is not signed with a certificate; DMG left unsigned"
fi

echo "▸ Done"
ls -la "$DMG"
shasum -a 256 "$DMG"
