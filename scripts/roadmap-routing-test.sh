#!/bin/bash
# Phase-routing logic test: compiles the UI-free cores behind Autopilot's
# token-cost routing (swift/Sources/suit/RoadmapParser.swift — the per-phase
# "model:"/"effort:" body annotations — and AutopilotDiffHash.swift — the
# review gate's unchanged-diff fingerprint) with
# scripts/roadmap-routing-test/main.swift and runs its assertions. The
# standalone-harness pattern; the full engine wiring is exercised by the slow
# scripts/autopilot-harness.sh.
#
# Usage: scripts/roadmap-routing-test.sh   (run from the repo root)
# Exit: 0 all pass, 1 an assertion failed, 64 compile failure.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DRIVER="$(mktemp -t roadmap-routing-test)"
trap 'rm -f "$DRIVER"' EXIT

echo "==> Compiling roadmap-routing logic test"
if ! swiftc -O \
    "$ROOT/swift/Sources/suit/RoadmapParser.swift" \
    "$ROOT/swift/Sources/suit/AutopilotDiffHash.swift" \
    "$ROOT/scripts/roadmap-routing-test/main.swift" \
    -o "$DRIVER"; then
    echo "COMPILE FAILED"
    exit 64
fi

echo "==> Running assertions"
"$DRIVER"
