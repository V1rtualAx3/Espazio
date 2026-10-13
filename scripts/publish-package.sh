#!/usr/bin/env bash
# Publishes the DMG and PKG of a stable release to GitHub Packages (ghcr.io) as an OCI artifact,
# tagged with the version and "latest". Called by semantic-release on main only.
#   $1  version (e.g. 1.2.0)
# Requires GITHUB_TOKEN with packages:write and GITHUB_ACTOR / GITHUB_REPOSITORY (set in CI).
# Download:  oras pull ghcr.io/<owner>/espazio:<version>
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?version required}"
ORAS_VERSION="1.2.0"
OWNER="$(echo "${GITHUB_REPOSITORY:?}" | cut -d/ -f1 | tr '[:upper:]' '[:lower:]')"
IMAGE="ghcr.io/${OWNER}/espazio"

if ! command -v oras >/dev/null; then
    ARCH="$(uname -m)"; [[ "$ARCH" == "x86_64" ]] && ARCH="amd64"
    OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
    curl -fsSL "https://github.com/oras-project/oras/releases/download/v${ORAS_VERSION}/oras_${ORAS_VERSION}_${OS}_${ARCH}.tar.gz" \
        | tar -xz -C build oras
    PATH="$PWD/build:$PATH"
fi

echo "${GITHUB_TOKEN:?}" | oras login ghcr.io -u "${GITHUB_ACTOR:?}" --password-stdin
cd build
oras push "${IMAGE}:${VERSION}" \
    --artifact-type application/vnd.espazio.installers.v1 \
    --annotation "org.opencontainers.image.source=https://github.com/${GITHUB_REPOSITORY}" \
    --annotation "org.opencontainers.image.title=Espazio" \
    --annotation "org.opencontainers.image.version=${VERSION}" \
    --annotation "org.opencontainers.image.description=Espazio ${VERSION} — DMG et PKG pour macOS" \
    "Espazio-${VERSION}.dmg:application/x-apple-diskimage" \
    "Espazio-${VERSION}.pkg:application/octet-stream"
oras tag "${IMAGE}:${VERSION}" latest
echo "Published ${IMAGE}:${VERSION} (and :latest)"
