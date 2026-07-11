#!/bin/bash
# Shareable-themes logic test: compiles the UI-free theme core
# (swift/Sources/suit/Theme.swift + ThemeStore.swift, which depend only on each
# other + Cocoa) with scripts/themes-test/main.swift and runs its assertions
# against a scratch $HOME — the .suittheme (de)serialization (partial decode
# with per-token fallback, unknown top-level/color-key tolerance, export->import
# round-trip equality), the hex parser edge cases (missing '#', wrong length,
# non-hex), and the ThemeStore catalog operations (duplicate produces an
# independent editable copy; delete removes only user themes). Mirrors the
# Recipes / Layouts standalone-test pattern.
#
# Theme.swift / ThemeStore.swift import Cocoa (NSColor), so this harness links
# AppKit — it still needs no running app.
#
# Usage: scripts/test-themes.sh   (run from the repo root)
# Exit: 0 all pass, 1 an assertion failed, 64 compile failure.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DRIVER="$(mktemp -t themes-test)"
SCRATCH="$(mktemp -d -t themes-test-home)"
trap 'rm -f "$DRIVER"; rm -rf "$SCRATCH"' EXIT

echo "==> Compiling shareable-themes logic test"
if ! swiftc -O \
    "$ROOT/swift/Sources/suit/Theme.swift" \
    "$ROOT/swift/Sources/suit/ThemeStore.swift" \
    "$ROOT/scripts/themes-test/main.swift" \
    -o "$DRIVER"; then
    echo "COMPILE FAILED"
    exit 64
fi

echo "==> Running (scratch HOME=$SCRATCH)"
HOME="$SCRATCH" "$DRIVER"
