#!/usr/bin/env bash
# Publishes a release to the Sparkle appcast (called by semantic-release once the GitHub release
# and its DMG exist). The appcast lives on the "appcast" branch, served at
#   https://raw.githubusercontent.com/V1rtualAx3/Espazio/appcast/appcast.xml  (SUFeedURL)
# Without SPARKLE_ED_PRIVATE_KEY the build has no update key and nothing is published.
#   $1  version, e.g. 1.0.0 or 1.0.0-beta.14
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?version required}"
if [[ -z "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
    echo "SPARKLE_ED_PRIVATE_KEY not set: appcast not updated (see docs/UPDATES.md)."
    exit 0
fi
REPO="${GITHUB_REPOSITORY:-V1rtualAx3/Espazio}"
BRANCH=appcast
DMG="build/Espazio-$VERSION.dmg"
[[ -f "$DMG" ]] || { echo "$DMG not found." >&2; exit 1; }

SIGNATURE="$(swift scripts/sparkle-eddsa.swift sign "$DMG")"
LENGTH="$(stat -f %z "$DMG")"
BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Resources/Info.plist)"
MINIMUM="$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" Resources/Info.plist)"

WORK="$(mktemp -d)"
trap 'git worktree remove --force "$WORK" 2>/dev/null || true' EXIT
if git fetch --quiet origin "$BRANCH" 2>/dev/null; then
    git worktree add --quiet --detach "$WORK" FETCH_HEAD
else
    git worktree add --quiet --detach "$WORK"
    git -C "$WORK" checkout --quiet --orphan "$BRANCH"
    git -C "$WORK" rm -rf --quiet .
fi

python3 scripts/appcast.py "$WORK/appcast.xml" \
    --version "$VERSION" --build "$BUILD" --length "$LENGTH" --signature "$SIGNATURE" \
    --url "https://github.com/$REPO/releases/download/v$VERSION/Espazio-$VERSION.dmg" \
    --notes-url "https://github.com/$REPO/releases/tag/v$VERSION" \
    --minimum-system "$MINIMUM"

git -C "$WORK" add appcast.xml
git -C "$WORK" -c user.name="${GIT_COMMITTER_NAME:-github-actions[bot]}" \
    -c user.email="${GIT_COMMITTER_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}" \
    commit --quiet -m "chore(appcast): Espazio $VERSION [skip ci]"
git -C "$WORK" push --quiet origin "HEAD:refs/heads/$BRANCH"
echo "Appcast updated with Espazio $VERSION."
