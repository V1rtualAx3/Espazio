#!/usr/bin/env bash
# Builds the release artifacts for a semantic-release version (called by @semantic-release/exec).
#   $1  full semantic version, e.g. 1.2.0 or 1.3.0-beta-claude-espazio-v1.2
# Info.plist is stamped in the CI workspace only (never committed):
#   CFBundleShortVersionString = numeric core (1.3.0), CFBundleVersion = CI run number,
#   EspazioVersion = full version (shown in About / diagnostics),
#   SUPublicEDKey = public key of $SPARKLE_ED_PRIVATE_KEY, when set (enables Sparkle updates).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?version required}"
CORE="${VERSION%%-*}"
BUILD="${GITHUB_RUN_NUMBER:-1}"
PLIST=Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $CORE" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"
/usr/libexec/PlistBuddy -c "Delete :EspazioVersion" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :EspazioVersion string $VERSION" "$PLIST"
if [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
    PUBLIC_KEY="$(swift scripts/sparkle-eddsa.swift public-key)"
    /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $PUBLIC_KEY" "$PLIST"
else
    echo "SPARKLE_ED_PRIVATE_KEY not set: build without in-app updates."
fi
ESPAZIO_VERSION="$VERSION" scripts/package.sh
scripts/smoke-test.sh
