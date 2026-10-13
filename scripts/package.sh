#!/usr/bin/env bash
# Builds Espazio.app then wraps it in a .dmg (drag-and-drop) and a .pkg (installs to /Applications).
#   CODESIGN_IDENTITY   app signing identity (default "-" = ad-hoc, local testing only)
#   INSTALLER_IDENTITY  "Developer ID Installer: …" to sign the .pkg (optional)
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
APP="build/Espazio.app"
DMG="build/Espazio-${VERSION}.dmg"
PKG="build/Espazio-${VERSION}.pkg"

# --- DMG: app + /Applications shortcut -------------------------------------------------
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "Espazio ${VERSION}" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"

# --- PKG: installs Espazio.app into /Applications --------------------------------------
PKG_ROOT="$(mktemp -d)"
mkdir -p "$PKG_ROOT/Applications"
cp -R "$APP" "$PKG_ROOT/Applications/"
COMPONENT_PLIST="$(mktemp)"
pkgbuild --analyze --root "$PKG_ROOT" "$COMPONENT_PLIST" >/dev/null
# Always install to /Applications, never relocate onto another copy found on disk.
/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "$COMPONENT_PLIST"
SIGN_ARGS=()
if [[ -n "${INSTALLER_IDENTITY:-}" ]]; then SIGN_ARGS=(--sign "$INSTALLER_IDENTITY"); fi
rm -f "$PKG"
pkgbuild --root "$PKG_ROOT" --component-plist "$COMPONENT_PLIST" --identifier app.espazio.Espazio.pkg \
  --version "$VERSION" --install-location / "${SIGN_ARGS[@]}" "$PKG" >/dev/null
rm -rf "$PKG_ROOT" "$COMPONENT_PLIST"
echo "Built $PKG ($(du -h "$PKG" | cut -f1))"
