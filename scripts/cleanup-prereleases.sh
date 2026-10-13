#!/usr/bin/env bash
# Deletes GitHub pre-releases and their tags.
#   --all      every pre-release (run after a stable release on main: betas are superseded)
#   --legacy   only pre-releases from the old branch-named scheme (vX.Y.Z-beta-<branch>.N)
# Requires the GitHub CLI and GH_TOKEN (provided in CI).
set -euo pipefail
MODE="${1:---all}"
gh release list --limit 200 --json tagName,isPrerelease --jq '.[] | select(.isPrerelease) | .tagName' |
while read -r tag; do
    case "$MODE" in
        --legacy) [[ "$tag" == *-beta-* ]] || continue ;;
        --all) ;;
        *) echo "unknown mode $MODE" >&2; exit 2 ;;
    esac
    echo "Deleting pre-release $tag"
    gh release delete "$tag" --cleanup-tag --yes
done
