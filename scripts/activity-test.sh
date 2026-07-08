#!/bin/bash
# Activity-feed logic test (ROADMAP Phase 38): compiles the UI-free core
# (swift/Sources/suit/Activity.swift, Foundation-only, no app deps) with
# scripts/activity-test/main.swift and runs its assertions — newest-first feed
# ordering (incl. deterministic ties), row routing (session > PR > autopilot
# log > none), repo/session/kind filtering, the daily-digest rollup across
# calendar days, and the append-only store's dedup + round-trip. Mirrors the
# RoadmapParser / FeedbackRouting / Recipes / FileEdit standalone-test pattern.
#
# Usage: scripts/activity-test.sh   (run from the repo root)
# Exit: 0 all pass, 1 an assertion failed, 64 compile failure.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DRIVER="$(mktemp -t activity-test)"
trap 'rm -f "$DRIVER"' EXIT

echo "==> Compiling activity-feed logic test"
if ! swiftc -O \
    "$ROOT/swift/Sources/suit/Activity.swift" \
    "$ROOT/scripts/activity-test/main.swift" \
    -o "$DRIVER"; then
    echo "COMPILE FAILED"
    exit 64
fi

echo "==> Running"
"$DRIVER"
