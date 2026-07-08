#!/bin/bash
# PR-review logic test (ROADMAP Phase 39): compiles the UI-free cores
# (swift/Sources/suit/PRReview.swift + DiffReview.swift, both Foundation-only,
# no app deps) with scripts/pr-review-test/main.swift and runs its assertions —
# the `gh pr list` JSON parse (fields / author.login / dedup / newest-first /
# check summary) and the `gh pr review` decision/body/argv composition from a
# diff-review draft. Mirrors the Recipes / FeedbackRouting standalone-test pattern.
#
# Usage: scripts/pr-review-test.sh   (run from the repo root)
# Exit: 0 all pass, 1 an assertion failed, 64 compile failure.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DRIVER="$(mktemp -t pr-review-test)"
trap 'rm -f "$DRIVER"' EXIT

echo "==> Compiling PR-review logic test"
if ! swiftc -O \
    "$ROOT/swift/Sources/suit/PRReview.swift" \
    "$ROOT/swift/Sources/suit/DiffReview.swift" \
    "$ROOT/scripts/pr-review-test/main.swift" \
    -o "$DRIVER"; then
    echo "COMPILE FAILED"
    exit 64
fi

echo "==> Running"
"$DRIVER"
