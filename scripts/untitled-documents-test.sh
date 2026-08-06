#!/bin/bash
# Untitled-document naming test: compiles the UI-free core
# (swift/Sources/suit/UntitledDocuments.swift, Foundation-only, no app deps)
# with scripts/untitled-documents-test/main.swift and runs its assertions — the
# lowest-free-index rule behind ⌘N, the strict prefix parse that stops a real
# file called Untitled-1.txt from stealing a slot, and the round-trip between a
# generated name and the index it encodes. Mirrors the FileEdit / Recipes
# standalone-test pattern.
#
# Usage: scripts/untitled-documents-test.sh   (run from the repo root)
# Exit: 0 all pass, 1 an assertion failed, 64 compile failure.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DRIVER="$(mktemp -t untitled-documents-test)"
trap 'rm -f "$DRIVER"' EXIT

echo "==> Compiling untitled-document naming test"
if ! swiftc -O \
    "$ROOT/swift/Sources/suit/UntitledDocuments.swift" \
    "$ROOT/scripts/untitled-documents-test/main.swift" \
    -o "$DRIVER"; then
    echo "COMPILE FAILED"
    exit 64
fi

echo "==> Running"
"$DRIVER"
