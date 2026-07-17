#!/bin/bash
# Raw-HTML markdown subset test: compiles the UI-free parser behind the
# markdown preview's HTML handling (swift/Sources/suit/MarkdownHTML.swift — the
# `<p align="center"><img></p>` README idiom, centered headings, badge rows,
# inline emphasis, and the fail-closed whitelist) with
# scripts/markdown-html-test/main.swift and runs its assertions. The
# standalone-harness pattern; MarkdownRenderer's NSAttributedString layout on
# top of it needs AppKit and is verified by rendering the real README.
#
# Usage: scripts/markdown-html-test.sh   (run from the repo root)
# Exit: 0 all pass, 1 an assertion failed, 64 compile failure.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DRIVER="$(mktemp -t markdown-html-test)"
trap 'rm -f "$DRIVER"' EXIT

echo "==> Compiling markdown-html logic test"
if ! swiftc -O \
    "$ROOT/swift/Sources/suit/MarkdownHTML.swift" \
    "$ROOT/scripts/markdown-html-test/main.swift" \
    -o "$DRIVER"; then
    echo "COMPILE FAILED"
    exit 64
fi

echo "==> Running assertions"
"$DRIVER"
