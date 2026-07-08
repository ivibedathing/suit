#!/bin/bash
# Symbol-index logic test (ROADMAP Phase 33): compiles the UI-free core
# (swift/Sources/suit/SymbolIndexCore.swift, Foundation-only, no app deps) with
# scripts/symbol-index-test/main.swift and runs its assertions — the ctags-tag
# parser, the identifier-under-caret extraction, the definition lookup and the
# reference regex, plus an end-to-end pass over a real Swift/Go fixture when a
# universal-ctags is installed. Mirrors the RoadmapParser/feedback-routing
# standalone-test pattern.
#
# Usage: scripts/symbol-index-test.sh   (run from the repo root)
# Exit: 0 all pass, 1 an assertion failed, 64 compile failure.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DRIVER="$(mktemp -t symbol-index-test)"
trap 'rm -f "$DRIVER"' EXIT

echo "==> Compiling symbol-index logic test"
if ! swiftc -O \
    "$ROOT/swift/Sources/suit/SymbolIndexCore.swift" \
    "$ROOT/scripts/symbol-index-test/main.swift" \
    -o "$DRIVER"; then
    echo "COMPILE FAILED"
    exit 64
fi

echo "==> Running"
"$DRIVER"
