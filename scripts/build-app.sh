#!/usr/bin/env bash
# Builds Espazio.app (release) from the Swift package and signs it.
#   CODESIGN_IDENTITY  signing identity (default "-" = ad-hoc, local use only)
#   CONFIGURATION      release (default) | debug
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION="${CONFIGURATION:-release}"
IDENTITY="${CODESIGN_IDENTITY:--}"
APP="build/Espazio.app"

swift build -c "$CONFIGURATION" --product Espazio
swift build -c "$CONFIGURATION" --product espazio-hook
BIN="$(swift build -c "$CONFIGURATION" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Espazio" "$APP/Contents/MacOS/Espazio"
cp "$BIN/espazio-hook" "$APP/Contents/MacOS/espazio-hook"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if command -v iconutil >/dev/null; then
    iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
fi

SIGN_FLAGS=(--force --options runtime --timestamp=none --sign "$IDENTITY")
codesign "${SIGN_FLAGS[@]}" "$APP/Contents/MacOS/espazio-hook"
codesign "${SIGN_FLAGS[@]}" --entitlements Resources/Espazio.entitlements "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

rm -f build/Espazio.zip
ditto -c -k --keepParent "$APP" build/Espazio.zip
echo "Built $APP ($(du -sh "$APP" | cut -f1))"
