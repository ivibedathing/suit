#!/bin/bash
# Project-wide replace logic test: compiles the UI-free core behind the sidebar's
# Search tab (swift/Sources/suit/SearchReplace.swift over
# swift/Sources/suit/FindReplace.swift — both Foundation-only, no app deps) with
# scripts/search-replace-test/main.swift and runs its assertions: the rg-options →
# FindQuery mapping, line-wise replacement (so ^/$ anchor per line the way rg
# matched), CRLF preservation, capture-group templates, the gate that refuses a
# mid-search or capped result set, the apply pass over injected file IO (including
# unreadable files and failed writes), and the confirm/summary prose. Mirrors the
# find-replace / editor-ops standalone-test pattern.
#
# Usage: scripts/search-replace-test.sh   (run from the repo root)
# Exit: 0 all pass, 1 an assertion failed, 64 compile failure.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DRIVER="$(mktemp -t search-replace-test)"
trap 'rm -f "$DRIVER"' EXIT

echo "==> Compiling search-replace logic test"
if ! swiftc -O \
    "$ROOT/swift/Sources/suit/FindReplace.swift" \
    "$ROOT/swift/Sources/suit/SearchReplace.swift" \
    "$ROOT/scripts/search-replace-test/main.swift" \
    -o "$DRIVER"; then
    echo "COMPILE FAILED"
    exit 64
fi

echo "==> Running"
"$DRIVER"
