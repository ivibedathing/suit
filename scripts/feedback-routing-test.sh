#!/bin/bash
# Feedback-routing logic test (ROADMAP Phase 29): compiles the UI-free core
# (swift/Sources/suit/FeedbackRouting.swift, Foundation-only, no app deps) with
# scripts/feedback-routing-test/main.swift and runs its assertions — the pure
# parsers (conflict porcelain, gh review/comment JSON, gh statusCheckRollup),
# the session-attribution rule (single/none/ambiguous/nil-cwd), and the composed
# prompts. Mirrors the RoadmapParser/AutopilotScheduler standalone-test pattern.
#
# Usage: scripts/feedback-routing-test.sh   (run from the repo root)
# Exit: 0 all pass, 1 an assertion failed, 64 compile failure.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DRIVER="$(mktemp -t feedback-routing-test)"
trap 'rm -f "$DRIVER"' EXIT

echo "==> Compiling feedback-routing logic test"
if ! swiftc -O \
    "$ROOT/swift/Sources/suit/FeedbackRouting.swift" \
    "$ROOT/scripts/feedback-routing-test/main.swift" \
    -o "$DRIVER"; then
    echo "COMPILE FAILED"
    exit 64
fi

echo "==> Running"
"$DRIVER"
