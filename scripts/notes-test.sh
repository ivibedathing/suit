#!/bin/bash
# Notes logic test: compiles the UI-free notes core
# (swift/Sources/suit/Notes.swift, Foundation-only, no app deps — plus
# FileWatch/FileWatcher, which it holds a directory watcher from) with
# scripts/notes-test/main.swift and runs its assertions — title-to-filename
# naming, collision suffixes, the directory scan's filtering and ordering,
# create/rename, the terminal selection capture, and the one-way import of the
# formats notes used to live in (notes.json and the older free-text notes.txt)
# against scratch $HOMEs. Mirrors the Recipes / Layouts standalone-test pattern.
#
# Usage: scripts/notes-test.sh   (run from the repo root)
# Exit: 0 all pass, 1 an assertion failed, 64 compile failure.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DRIVER="$(mktemp -t notes-test)"
SCRATCH="$(mktemp -d -t notes-test-home)"
trap 'rm -f "$DRIVER"; rm -rf "$SCRATCH"' EXIT

echo "==> Compiling notes logic test"
if ! swiftc -O \
    "$ROOT/swift/Sources/suit/Notes.swift" \
    "$ROOT/swift/Sources/suit/FileWatch.swift" \
    "$ROOT/swift/Sources/suit/FileWatcher.swift" \
    "$ROOT/scripts/notes-test/main.swift" \
    -o "$DRIVER"; then
    echo "COMPILE FAILED"
    exit 64
fi

echo "==> Running (scratch HOME=$SCRATCH)"
HOME="$SCRATCH" "$DRIVER"
