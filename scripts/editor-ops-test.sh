#!/bin/bash
# Editor-core logic test: compiles the UI-free editing cores
# (swift/Sources/suit/EditorOps.swift and swift/Sources/suit/CodeFolding.swift —
# both Foundation-only, no app deps) with scripts/editor-ops-test/main.swift and
# runs its assertions: auto-indent on Return, bracket/quote auto-close and
# skip-over, comment toggling, indent/outdent, the ⌘D occurrence walk, column
# selection, and brace/indentation fold regions. Mirrors the find-replace /
# file-edit standalone-test pattern.
#
# Usage: scripts/editor-ops-test.sh   (run from the repo root)
# Exit: 0 all pass, 1 an assertion failed, 64 compile failure.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DRIVER="$(mktemp -t editor-ops-test)"
trap 'rm -f "$DRIVER"' EXIT

echo "==> Compiling editor-ops logic test"
if ! swiftc -O \
    "$ROOT/swift/Sources/suit/EditorOps.swift" \
    "$ROOT/swift/Sources/suit/CodeFolding.swift" \
    "$ROOT/scripts/editor-ops-test/main.swift" \
    -o "$DRIVER"; then
    echo "COMPILE FAILED"
    exit 64
fi

echo "==> Running"
"$DRIVER"
