#!/bin/bash
# Cache hit-rate meter logic test: compiles the UI-free core
# (swift/Sources/suit/CacheStats.swift, Foundation-only, no app deps) with
# scripts/cache-stats-test/main.swift and runs its assertions — transcript
# usage parsing, the rolling hit-rate math, the whole-lines file tail, and
# the edge-triggered collapse monitor. The standalone-harness pattern; the
# AppKit half (CacheStatsGuard, fleet-row readout) is exercised by the app.
#
# Usage: scripts/cache-stats-test.sh   (run from the repo root)
# Exit: 0 all pass, 1 an assertion failed, 64 compile failure.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DRIVER="$(mktemp -t cache-stats-test)"
trap 'rm -f "$DRIVER"' EXIT

echo "==> Compiling cache-stats logic test"
if ! swiftc -O \
    "$ROOT/swift/Sources/suit/CacheStats.swift" \
    "$ROOT/scripts/cache-stats-test/main.swift" \
    -o "$DRIVER"; then
    echo "COMPILE FAILED"
    exit 64
fi

echo "==> Running assertions"
"$DRIVER"
