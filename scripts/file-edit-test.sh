#!/bin/bash
# File-edit logic test (ROADMAP Phase 37): compiles the UI-free core
# (swift/Sources/suit/FileEdit.swift, Foundation-only, no app deps) with
# scripts/file-edit-test/main.swift and runs its assertions — the dirty-flag
# transitions (flip on first divergence / revert), the save & load baseline
# resets, the external-change reconciliation decision (ignore/reload/warn), and
# the atomic writer's exact round-trip. Mirrors the Recipes / FeedbackRouting
# standalone-test pattern.
#
# Usage: scripts/file-edit-test.sh   (run from the repo root)
# Exit: 0 all pass, 1 an assertion failed, 64 compile failure.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DRIVER="$(mktemp -t file-edit-test)"
trap 'rm -f "$DRIVER"' EXIT

echo "==> Compiling file-edit logic test"
if ! swiftc -O \
    "$ROOT/swift/Sources/suit/FileEdit.swift" \
    "$ROOT/scripts/file-edit-test/main.swift" \
    -o "$DRIVER"; then
    echo "COMPILE FAILED"
    exit 64
fi

echo "==> Running"
"$DRIVER"
