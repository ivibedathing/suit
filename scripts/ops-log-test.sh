#!/bin/bash
# Operations-log logic test: compiles the UI-free core
# (swift/Sources/suit/OpsLog.swift, Foundation-only, no app deps) with
# scripts/ops-log-test/main.swift and runs its assertions — argv→label
# derivation for git/gh/rg/ctags/shell, the ring buffer's bound and monotonic
# sequence, measure()'s outcome derivation, the scoped ambient trigger,
# adjacent-run collapsing, the rolling-window rollup, filtering and the
# duration/age formatters. Mirrors the FeedbackRouting / Activity
# standalone-test pattern.
#
# Usage: scripts/ops-log-test.sh   (run from the repo root)
# Exit: 0 all pass, 1 an assertion failed, 64 compile failure.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DRIVER="$(mktemp -t ops-log-test)"
trap 'rm -f "$DRIVER"' EXIT

echo "==> Compiling operations-log logic test"
if ! swiftc -O \
    "$ROOT/swift/Sources/suit/OpsLog.swift" \
    "$ROOT/scripts/ops-log-test/main.swift" \
    -o "$DRIVER"; then
    echo "COMPILE FAILED"
    exit 64
fi

echo "==> Running"
"$DRIVER"
