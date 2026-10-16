#!/usr/bin/env bash
# Betas published before all work branches shared the "beta" channel carry their branch name as
# channel in semantic-release's git note, so later runs ignore them and try to reuse their tag.
# Rewrites those notes to the "beta" channel. Idempotent; pushes only what changed.
set -euo pipefail

export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-semantic-release-bot}" GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-semantic-release-bot@martynus.net}"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

git fetch --quiet origin '+refs/notes/semantic-release*:refs/notes/semantic-release*' || true

changed=()
for tag in $(git tag --list 'v*-beta.*'); do
  ref="semantic-release-${tag}"
  note=$(git notes --ref "$ref" show "$tag" 2>/dev/null || true)
  [[ -z "$note" || "$note" == *'"beta"'* ]] && continue
  git notes --ref "$ref" add -f -m '{"channels":["beta"]}' "$tag"
  changed+=("refs/notes/${ref}")
  echo "Moved ${tag} to the beta channel (was ${note})."
done

if (( ${#changed[@]} )); then
  git push --force origin "${changed[@]}"
fi
