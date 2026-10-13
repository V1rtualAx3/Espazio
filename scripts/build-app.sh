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
cp Resources/MenuBar/MenuBarIcon.png Resources/MenuBar/MenuBarIcon@2x.png "$APP/Contents/Resources/"
# Embed Sparkle.framework (resolved by SwiftPM next to the products).
if [[ -d "$BIN/Sparkle.framework" ]]; then
    mkdir -p "$APP/Contents/Frameworks"
    ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"
if command -v iconutil >/dev/null; then
    iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
fi

# Hardened runtime only with a real identity: with ad-hoc signing ("-") there is no Team ID, so
# library validation would refuse to load the embedded Sparkle.framework and the app would die
# at launch. Notarization requires a Developer ID anyway.
if [[ "$IDENTITY" == "-" ]]; then
    SIGN_FLAGS=(--force --timestamp=none --sign "$IDENTITY")
else
    SIGN_FLAGS=(--force --options runtime --timestamp --sign "$IDENTITY")
fi
codesign "${SIGN_FLAGS[@]}" "$APP/Contents/MacOS/espazio-hook"
if [[ -d "$APP/Contents/Frameworks/Sparkle.framework" ]]; then
    # Sign Sparkle's nested helpers inside-out, then the framework.
    SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
    for item in "$SPARKLE/XPCServices/"*.xpc "$SPARKLE/Autoupdate" "$SPARKLE/Updater.app"; do
        [[ -e "$item" ]] && codesign "${SIGN_FLAGS[@]}" "$item"
    done
    codesign "${SIGN_FLAGS[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
fi
codesign "${SIGN_FLAGS[@]}" --entitlements Resources/Espazio.entitlements "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

rm -f build/Espazio.zip
ditto -c -k --keepParent "$APP" build/Espazio.zip
echo "Built $APP ($(du -sh "$APP" | cut -f1))"
