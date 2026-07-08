#!/bin/bash
# Broadcast logic test (ROADMAP Phase 35): compiles the UI-free core
# (swift/Sources/suit/Broadcast.swift, Foundation-only, no app deps) with
# scripts/broadcast-test/main.swift and runs its assertions — the pure target
# resolution (scope × hosted × fleet order, dedup, orphan drop) and the fan-out
# confirm rule. Mirrors the feedback-routing / RoadmapParser standalone-test
# pattern.
#
# Usage: scripts/broadcast-test.sh   (run from the repo root)
# Exit: 0 all pass, 1 an assertion failed, 64 compile failure.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DRIVER="$(mktemp -t broadcast-test)"
trap 'rm -f "$DRIVER"' EXIT

echo "==> Compiling broadcast logic test"
if ! swiftc -O \
    "$ROOT/swift/Sources/suit/Broadcast.swift" \
    "$ROOT/scripts/broadcast-test/main.swift" \
    -o "$DRIVER"; then
    echo "COMPILE FAILED"
    exit 64
fi

echo "==> Running"
"$DRIVER"
