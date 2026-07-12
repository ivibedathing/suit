#!/bin/bash
# Unified-diff parser logic test: compiles the UI-free core
# (swift/Sources/suit/DiffParser.swift, Foundation-only, no app deps) with
# scripts/diffparser-test/main.swift and runs its assertions — line
# classification (file/hunk headers, meta, context, additions, deletions),
# old/new line-number tracking across single and multiple hunks, context-prefix
# stripping, and changedPaths() (multi-file order + rename b/-side). Mirrors the
# RoadmapParser / FeedbackRouting / Recipes standalone-test pattern.
#
# Usage: scripts/diffparser-test.sh   (run from the repo root)
# Exit: 0 all pass, 1 an assertion failed, 64 compile failure.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DRIVER="$(mktemp -t diffparser-test)"
trap 'rm -f "$DRIVER"' EXIT

echo "==> Compiling unified-diff parser logic test"
if ! swiftc -O \
    "$ROOT/swift/Sources/suit/DiffParser.swift" \
    "$ROOT/scripts/diffparser-test/main.swift" \
    -o "$DRIVER"; then
    echo "COMPILE FAILED"
    exit 64
fi

echo "==> Running"
"$DRIVER"
