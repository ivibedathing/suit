#!/bin/bash
# Token-savings ledger logic test: compiles the UI-free core
# (swift/Sources/suit/TokenSavings.swift, Foundation-only, no app deps) with
# scripts/token-savings-test/main.swift and runs its assertions — per-session
# JSONL aggregation, the chars/4 token estimate (matching
# scripts/token-savings-report.sh), torn/partial-line tolerance, the
# incremental file tail with its truncation/deletion resets, and the compact
# "↓12k" formatting the pane title-bar counter shows. Mirrors the
# BudgetGuardrails / FeedbackRouting standalone-test pattern.
#
# Usage: scripts/token-savings-test.sh   (run from the repo root)
# Exit: 0 all pass, 1 an assertion failed, 64 compile failure.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DRIVER="$(mktemp -t token-savings-test)"
trap 'rm -f "$DRIVER"' EXIT

echo "==> Compiling token-savings logic test"
if ! swiftc -O \
    "$ROOT/swift/Sources/suit/TokenSavings.swift" \
    "$ROOT/scripts/token-savings-test/main.swift" \
    -o "$DRIVER"; then
    echo "COMPILE FAILED"
    exit 64
fi

echo "==> Running"
"$DRIVER"
