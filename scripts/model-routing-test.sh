#!/bin/bash
# Model-routing logic test: compiles the UI-free core
# (swift/Sources/suit/ModelRouting.swift, Foundation-only, no app deps) with
# scripts/model-routing-test/main.swift and runs its assertions — verdict
# parsing (including the small-model failure modes it must tolerate), the
# annotation > classifier > heuristic precedence, the heuristic fallback's
# upward bias, and the review-gate tier floor. Mirrors the
# RoadmapParser/FeedbackRouting standalone-test pattern.
#
# ModelRouter.swift (the Process half) is deliberately excluded — it shells out
# to claude, which a logic test must never do. If ModelRouting.swift ever grows
# an app or AppKit dependency, this compile breaks, which is the point.
#
# Usage: scripts/model-routing-test.sh   (run from the repo root)
# Exit: 0 all pass, 1 an assertion failed, 64 compile failure.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DRIVER="$(mktemp -t model-routing-test)"
trap 'rm -f "$DRIVER"' EXIT

echo "==> Compiling model-routing logic test"
if ! swiftc -O \
    "$ROOT/swift/Sources/suit/ModelRouting.swift" \
    "$ROOT/scripts/model-routing-test/main.swift" \
    -o "$DRIVER"; then
    echo "COMPILE FAILED"
    exit 64
fi

echo "==> Running"
"$DRIVER"
