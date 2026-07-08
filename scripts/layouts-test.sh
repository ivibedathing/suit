#!/bin/bash
# Saved-layouts logic test (ROADMAP Phase 41): compiles the UI-free layout core
# (swift/Sources/suit/Layouts.swift) together with the state-restoration shapes
# it snapshots (StateRestoration.swift + DiffReview.swift, both needed for
# SavedWindow/SavedTab and its Codable review comments) and
# scripts/layouts-test/main.swift, then runs its assertions — the catalog
# operations (save/overwrite/rename/delete/sort), the LayoutStore disk
# round-trip against a scratch $HOME, and the restore-time pruning that
# collapses a pane whose backing file is gone. Mirrors the Recipes / FileEdit /
# FeedbackRouting standalone-test pattern.
#
# StateRestoration.swift imports Cocoa (NSRect's Codable conformance lives in
# AppKit), so this harness links AppKit — it still needs no running app.
#
# Usage: scripts/layouts-test.sh   (run from the repo root)
# Exit: 0 all pass, 1 an assertion failed, 64 compile failure.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DRIVER="$(mktemp -t layouts-test)"
SCRATCH="$(mktemp -d -t layouts-test-home)"
trap 'rm -f "$DRIVER"; rm -rf "$SCRATCH"' EXIT

echo "==> Compiling saved-layouts logic test"
if ! swiftc -O \
    "$ROOT/swift/Sources/suit/Layouts.swift" \
    "$ROOT/swift/Sources/suit/StateRestoration.swift" \
    "$ROOT/swift/Sources/suit/DiffReview.swift" \
    "$ROOT/scripts/layouts-test/main.swift" \
    -o "$DRIVER"; then
    echo "COMPILE FAILED"
    exit 64
fi

echo "==> Running (scratch HOME=$SCRATCH)"
HOME="$SCRATCH" "$DRIVER"
