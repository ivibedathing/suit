#!/bin/bash
# Dictation text-core logic test: compiles the UI-free core
# (swift/Sources/suit/DictationText.swift, Foundation-only, no app deps) with
# scripts/dictation-test/main.swift and runs its assertions — transcript
# normalization (whitespace/newline collapse, trimming) and the sendable check
# that gates SessionControl.send. Mirrors the RoadmapParser / FeedbackRouting /
# Recipes standalone-test pattern; the AVAudioEngine / SFSpeechRecognizer half
# in Dictation.swift is UI/framework-bound and not covered here.
#
# Usage: scripts/dictation-test.sh   (run from the repo root)
# Exit: 0 all pass, 1 an assertion failed, 64 compile failure.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DRIVER="$(mktemp -t dictation-test)"
trap 'rm -f "$DRIVER"' EXIT

echo "==> Compiling dictation text-core test"
if ! swiftc -O \
    "$ROOT/swift/Sources/suit/DictationText.swift" \
    "$ROOT/scripts/dictation-test/main.swift" \
    -o "$DRIVER"; then
    echo "COMPILE FAILED"
    exit 64
fi

echo "==> Running"
"$DRIVER"
