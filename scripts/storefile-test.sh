#!/bin/bash
# StoreFile logic test: compiles the UI-free core
# (swift/Sources/suit/StoreFile.swift, Foundation-only, no app deps) with
# scripts/storefile-test/main.swift and runs its assertions — the shared
# ~/.suit JSON-store load helper's data-loss guard: a valid file decodes and is
# left in place, a present-but-corrupt file is quarantined (bytes preserved)
# rather than wiped by the next save, and an absent file is a clean empty start.
# Mirrors the RoadmapParser / DiffParser / Recipes standalone-test pattern.
#
# Usage: scripts/storefile-test.sh   (run from the repo root)
# Exit: 0 all pass, 1 an assertion failed, 64 compile failure.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DRIVER="$(mktemp -t storefile-test)"
trap 'rm -f "$DRIVER"' EXIT

echo "==> Compiling StoreFile logic test"
if ! swiftc -O \
    "$ROOT/swift/Sources/suit/StoreFile.swift" \
    "$ROOT/scripts/storefile-test/main.swift" \
    -o "$DRIVER"; then
    echo "COMPILE FAILED"
    exit 64
fi

echo "==> Running"
"$DRIVER"
