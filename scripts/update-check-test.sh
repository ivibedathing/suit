#!/bin/bash
# UpdateCheckCore logic test: compiles the UI-free core
# (swift/Sources/suit/UpdateCheckCore.swift, Foundation-only, no app deps) with
# scripts/update-check-test/main.swift and runs its assertions — GitHub release
# JSON parsing (.dmg asset pick, draft/prerelease refusal), the lenient version
# comparison, the offer gate with the Skip This Version override, and the
# daily-check throttle. Mirrors the RoadmapParser / StoreFile standalone-test
# pattern.
#
# Usage: scripts/update-check-test.sh   (run from the repo root)
# Exit: 0 all pass, 1 an assertion failed, 64 compile failure.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DRIVER="$(mktemp -t update-check-test)"
trap 'rm -f "$DRIVER"' EXIT

echo "==> Compiling UpdateCheckCore logic test"
if ! swiftc -O \
    "$ROOT/swift/Sources/suit/UpdateCheckCore.swift" \
    "$ROOT/scripts/update-check-test/main.swift" \
    -o "$DRIVER"; then
    echo "COMPILE FAILED"
    exit 64
fi

echo "==> Running"
"$DRIVER"
