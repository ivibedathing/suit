#!/bin/bash
# Find/replace logic test: compiles the UI-free core
# (swift/Sources/suit/FindReplace.swift, Foundation-only, no app deps) with
# scripts/find-replace-test/main.swift and runs its assertions — literal and
# regex matching, the whole-word boundary filter, case sensitivity, the
# caret-relative initial match and the wrapping next/prev step, capture-group
# templates, and replaceAll's offset handling. Mirrors the file-edit /
# FeedbackRouting standalone-test pattern.
#
# Usage: scripts/find-replace-test.sh   (run from the repo root)
# Exit: 0 all pass, 1 an assertion failed, 64 compile failure.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DRIVER="$(mktemp -t find-replace-test)"
trap 'rm -f "$DRIVER"' EXIT

echo "==> Compiling find-replace logic test"
if ! swiftc -O \
    "$ROOT/swift/Sources/suit/FindReplace.swift" \
    "$ROOT/scripts/find-replace-test/main.swift" \
    -o "$DRIVER"; then
    echo "COMPILE FAILED"
    exit 64
fi

echo "==> Running"
"$DRIVER"
