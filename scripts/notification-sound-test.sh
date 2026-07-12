#!/bin/bash
# Notification-sound logic test: compiles the UI-free core
# (swift/Sources/suit/NotificationSoundCore.swift, Foundation-only, no app
# deps) with scripts/notification-sound-test/main.swift and runs its
# assertions — the transition-to-event decision, the two enable-flag gates,
# dedup across sessions, and the no-transition / first-seen rules. Mirrors the
# Recipes / RoadmapParser standalone-test pattern.
#
# Usage: scripts/notification-sound-test.sh   (run from the repo root)
# Exit: 0 all pass, 1 an assertion failed, 64 compile failure.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DRIVER="$(mktemp -t notification-sound-test)"
trap 'rm -f "$DRIVER"' EXIT

echo "==> Compiling notification-sound logic test"
if ! swiftc -O \
    "$ROOT/swift/Sources/suit/NotificationSoundCore.swift" \
    "$ROOT/scripts/notification-sound-test/main.swift" \
    -o "$DRIVER"; then
    echo "COMPILE FAILED"
    exit 64
fi

echo "==> Running"
"$DRIVER"
