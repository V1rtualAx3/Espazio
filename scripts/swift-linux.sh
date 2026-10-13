#!/usr/bin/env bash
# Runs a SwiftPM command for the cross-platform targets inside the official Swift Linux image.
# Usage: scripts/swift-linux.sh build | test [args…]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec docker run --rm -v "$ROOT":/src -w /src swift:6.1-noble swift "$@" --scratch-path /src/.build-linux
