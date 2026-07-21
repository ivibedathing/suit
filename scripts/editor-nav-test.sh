#!/bin/bash
# Symbol-navigation logic test: compiles the UI-free navigation cores
# (swift/Sources/suit/SymbolOutline.swift and swift/Sources/suit/NavigationHistory.swift,
# against the existing SymbolIndexCore types — all Foundation-only) with
# scripts/editor-nav-test/main.swift and runs its assertions: outline entries and
# their nesting depth, the caret breadcrumb, fuzzy ranking, and the browser-style
# back/forward jump stack. Mirrors the find-replace / file-edit pattern.
#
# Usage: scripts/editor-nav-test.sh   (run from the repo root)
# Exit: 0 all pass, 1 an assertion failed, 64 compile failure.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DRIVER="$(mktemp -t editor-nav-test)"
trap 'rm -f "$DRIVER"' EXIT

echo "==> Compiling editor-nav logic test"
if ! swiftc -O \
    "$ROOT/swift/Sources/suit/SymbolIndexCore.swift" \
    "$ROOT/swift/Sources/suit/SymbolOutline.swift" \
    "$ROOT/swift/Sources/suit/NavigationHistory.swift" \
    "$ROOT/scripts/editor-nav-test/main.swift" \
    -o "$DRIVER"; then
    echo "COMPILE FAILED"
    exit 64
fi

echo "==> Running"
"$DRIVER"
