#!/bin/bash
# Bundled-font logic test: compiles the UI-free core
# (swift/Sources/suit/BundledFonts.swift, Foundation + CoreText only, no app
# deps) with scripts/bundled-fonts-test/main.swift and runs its assertions —
# the one-shot "move an existing install off the old system-monospaced default"
# migration rule, TTF discovery in both the bundle and the checkout, and that
# registering actually makes all four Hack faces resolvable instead of letting
# CoreText silently substitute. Mirrors the Recipes / FeedbackRouting pattern.
#
# Usage: scripts/bundled-fonts-test.sh   (run from the repo root)
# Exit: 0 all pass, 1 an assertion failed, 64 compile failure.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DRIVER="$(mktemp -t bundled-fonts-test)"
trap 'rm -f "$DRIVER"' EXIT

echo "==> Compiling bundled-fonts logic test"
if ! swiftc -O \
    "$ROOT/swift/Sources/suit/BundledFonts.swift" \
    "$ROOT/scripts/bundled-fonts-test/main.swift" \
    -o "$DRIVER"; then
    echo "COMPILE FAILED"
    exit 64
fi

echo "==> Running"
"$DRIVER"
