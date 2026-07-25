#!/bin/bash
# Project-search highlight test: compiles the UI-free core
# (swift/Sources/suit/SearchHighlight.swift plus the FindReplace matching and the
# EditorOps line math it composes — all Foundation-only, no app deps) with
# scripts/search-highlight-test/main.swift and runs its assertions: which ranges
# the viewer washes for the sidebar's Search pattern, which lines earn a minimap
# tick (deduped per line, following each match's start), how the query's
# case/regex options carry over from rg, and both caps. Mirrors the find-replace
# / editor-ops standalone-test pattern.
#
# Usage: scripts/search-highlight-test.sh   (run from the repo root)
# Exit: 0 all pass, 1 an assertion failed, 64 compile failure.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DRIVER="$(mktemp -t search-highlight-test)"
trap 'rm -f "$DRIVER"' EXIT

echo "==> Compiling search-highlight logic test"
if ! swiftc -O \
    "$ROOT/swift/Sources/suit/SearchHighlight.swift" \
    "$ROOT/swift/Sources/suit/FindReplace.swift" \
    "$ROOT/swift/Sources/suit/EditorOps.swift" \
    "$ROOT/scripts/search-highlight-test/main.swift" \
    -o "$DRIVER"; then
    echo "COMPILE FAILED"
    exit 64
fi

echo "==> Running"
"$DRIVER"
