#!/bin/bash
# Command-history logic test (ROADMAP Phase 43): compiles the UI-free core
# (swift/Sources/suit/CommandHistory.swift + FuzzyMatch.swift, Foundation-only,
# no app deps) with scripts/command-history-test/main.swift and runs its
# assertions — zsh-history parse/dedup (most-recent-first), the fuzzy ranking
# the overlay shows, source merging + the missing-$HISTFILE degrade path, the
# run/edit pty payload (edit-before-run leaves the line unsubmitted), and the
# destructive-command detection. Mirrors the AutopilotScheduler / FeedbackRouting
# standalone-test pattern.
#
# Usage: scripts/command-history-test.sh   (run from the repo root)
# Exit: 0 all pass, 1 an assertion failed, 64 compile failure.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DRIVER="$(mktemp -t command-history-test)"
trap 'rm -f "$DRIVER"' EXIT

echo "==> Compiling command-history logic test"
if ! swiftc -O \
    "$ROOT/swift/Sources/suit/FuzzyMatch.swift" \
    "$ROOT/swift/Sources/suit/CommandHistory.swift" \
    "$ROOT/scripts/command-history-test/main.swift" \
    -o "$DRIVER"; then
    echo "COMPILE FAILED"
    exit 64
fi

echo "==> Running"
"$DRIVER"
