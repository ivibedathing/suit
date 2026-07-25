#!/bin/bash
# Syntax-highlighting core test: compiles the UI-free highlighter
# (swift/Sources/suit/SyntaxLanguages.swift — the language table plus the
# scanner, Foundation-only with no AppKit) together with
# scripts/syntax-highlight-test/main.swift and runs its assertions: extension
# and filename detection, the generic code tokenizer, HTML/XML markup including
# embedded <script>/<style>, CSS/SCSS selector-vs-declaration context, and the
# span-bounds invariant the viewer's addAttribute depends on. Mirrors the
# editor-ops / find-replace standalone-test pattern.
#
# Usage: scripts/syntax-highlight-test.sh   (run from the repo root)
# Exit: 0 all pass, 1 an assertion failed, 64 compile failure.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DRIVER="$(mktemp -t syntax-highlight-test)"
trap 'rm -f "$DRIVER"' EXIT

echo "==> Compiling syntax-highlight logic test"
if ! swiftc -O \
    "$ROOT/swift/Sources/suit/SyntaxLanguages.swift" \
    "$ROOT/scripts/syntax-highlight-test/main.swift" \
    -o "$DRIVER"; then
    echo "COMPILE FAILED"
    exit 64
fi

echo "==> Running"
"$DRIVER"
