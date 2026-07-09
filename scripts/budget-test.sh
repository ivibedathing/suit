#!/bin/bash
# Budget-guardrails logic test (ROADMAP Phase 42): compiles the UI-free core
# (swift/Sources/suit/BudgetGuardrails.swift, Foundation-only, no app deps) with
# scripts/budget-test/main.swift and runs its assertions — cap resolution
# (per-session override vs default), the fires-once-at-the-threshold trip logic,
# auto-interrupt targeting the right pty, fall-back-and-re-cross, and a ≤ 0 cap
# never tripping. Mirrors the AutopilotScheduler / FeedbackRouting standalone-test
# pattern.
#
# Usage: scripts/budget-test.sh   (run from the repo root)
# Exit: 0 all pass, 1 an assertion failed, 64 compile failure.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DRIVER="$(mktemp -t budget-test)"
trap 'rm -f "$DRIVER"' EXIT

echo "==> Compiling budget-guardrails logic test"
if ! swiftc -O \
    "$ROOT/swift/Sources/suit/BudgetGuardrails.swift" \
    "$ROOT/scripts/budget-test/main.swift" \
    -o "$DRIVER"; then
    echo "COMPILE FAILED"
    exit 64
fi

echo "==> Running"
"$DRIVER"
