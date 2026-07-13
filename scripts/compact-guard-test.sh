#!/bin/bash
# Auto-/compact guardrails logic test: compiles the UI-free core
# (swift/Sources/suit/CompactGuardrails.swift, Foundation-only, no app deps)
# with scripts/compact-guard-test/main.swift and runs its assertions — fires
# once at the crossing, only at an idle prompt, hysteresis re-arm, cooldown,
# and never on stale/unhosted/busy/needs-input sessions. Mirrors the
# BudgetGuardrails / FeedbackRouting standalone-test pattern.
#
# Usage: scripts/compact-guard-test.sh   (run from the repo root)
# Exit: 0 all pass, 1 an assertion failed, 64 compile failure.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DRIVER="$(mktemp -t compact-guard-test)"
trap 'rm -f "$DRIVER"' EXIT

echo "==> Compiling compact-guardrails logic test"
if ! swiftc -O \
    "$ROOT/swift/Sources/suit/CompactGuardrails.swift" \
    "$ROOT/scripts/compact-guard-test/main.swift" \
    -o "$DRIVER"; then
    echo "COMPILE FAILED"
    exit 64
fi

echo "==> Running"
"$DRIVER"
