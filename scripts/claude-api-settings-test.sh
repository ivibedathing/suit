#!/bin/bash
# Claude API settings logic test: compiles the UI-free core
# (swift/Sources/suit/ClaudeAPISettings.swift, Foundation-only, no app deps)
# with scripts/claude-api-settings-test/main.swift and runs its assertions —
# env-assignment composition (which knobs emit which variables), shell quoting
# (embedded quotes, newline flattening), extra-env parsing/override semantics,
# and the defaults-pass-through guarantee. Mirrors the BudgetGuardrails /
# FeedbackRouting standalone-test pattern.
#
# Usage: scripts/claude-api-settings-test.sh   (run from the repo root)
# Exit: 0 all pass, 1 an assertion failed, 64 compile failure.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DRIVER="$(mktemp -t claude-api-settings-test)"
trap 'rm -f "$DRIVER"' EXIT

echo "==> Compiling claude-api-settings logic test"
if ! swiftc -O \
    "$ROOT/swift/Sources/suit/ClaudeAPISettings.swift" \
    "$ROOT/scripts/claude-api-settings-test/main.swift" \
    -o "$DRIVER"; then
    echo "COMPILE FAILED"
    exit 64
fi

echo "==> Running"
"$DRIVER"
