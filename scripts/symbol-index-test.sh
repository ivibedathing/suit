#!/bin/bash
# Symbol-index logic test (ROADMAP Phase 33): compiles the UI-free core
# (swift/Sources/suit/SymbolIndex.swift, Foundation-only, no app deps) with
# scripts/symbol-index-test/main.swift and runs its assertions — the ctags JSON
# tag parser, the identifier extractor, the go-to-definition outcome / header
# note / whole-word search logic, the SUIT_CTAGS_PATH resolver, and an
# end-to-end runCtags round-trip against a fake universal-ctags (single- and
# multi-definition, and a broken binary degrading to the rg fallback). Mirrors
# the RoadmapParser / FeedbackRouting standalone-test pattern.
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
    "$ROOT/swift/Sources/suit/SymbolIndex.swift" \
    "$ROOT/scripts/symbol-index-test/main.swift" \
    -o "$DRIVER"; then
    echo "COMPILE FAILED"
    exit 64
fi

echo "==> Running"
"$DRIVER"
