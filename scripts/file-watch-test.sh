#!/bin/bash
# File-watch test, in two halves. The pure half compiles the UI-free core
# (swift/Sources/suit/FileWatch.swift, Foundation-only, no app deps) with
# scripts/file-watch-test/main.swift: the event classification that decides
# re-read vs. re-open, the re-arm backoff, and the FileStamp change comparison
# including a same-length atomic rewrite. The live half adds FileWatcher.swift
# and drives it against a real file and run loop (a few seconds) — the
# descriptor-lifecycle bugs, which no pure test can see. Mirrors the FileEdit /
# Recipes standalone-test pattern.
#
# Usage: scripts/file-watch-test.sh   (run from the repo root)
# Exit: 0 all pass, 1 an assertion failed, 64 compile failure.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DRIVER="$(mktemp -t file-watch-test)"
LIVE_DRIVER="$(mktemp -t file-watch-live)"
trap 'rm -f "$DRIVER" "$LIVE_DRIVER"' EXIT

echo "==> Compiling file-watch logic test"
if ! swiftc -O \
    "$ROOT/swift/Sources/suit/FileWatch.swift" \
    "$ROOT/scripts/file-watch-test/main.swift" \
    -o "$DRIVER"; then
    echo "COMPILE FAILED"
    exit 64
fi

echo "==> Running"
"$DRIVER"

# Second half: FileWatcher (Foundation-only too — Dispatch + RunLoop, no AppKit)
# driven against a real file and a real run loop. The descriptor-lifecycle
# failures are invisible to the pure test, so this is where the atomic-replace
# deafness and the delete-then-recreate gap are actually caught. A few seconds of
# wall clock, set well past the coalesce window and re-arm backoff.
echo "==> Compiling file-watch live test"
if ! swiftc -O \
    "$ROOT/swift/Sources/suit/FileWatch.swift" \
    "$ROOT/swift/Sources/suit/FileWatcher.swift" \
    "$ROOT/scripts/file-watch-test/live/main.swift" \
    -o "$LIVE_DRIVER"; then
    echo "COMPILE FAILED"
    exit 64
fi

echo "==> Running"
"$LIVE_DRIVER"
