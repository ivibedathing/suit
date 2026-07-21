#!/bin/bash
# Branch-actions logic test: compiles the UI-free core
# (swift/Sources/suit/GitBranchOps.swift, Foundation-only, no app deps) with
# scripts/git-branch-ops-test/main.swift and runs its assertions — upstream
# track parsing and the sync badge, the git argv each action composes (pull is
# --ff-only, stash includes untracked, discard is reset + clean, and nothing
# force-pushes), which actions must carry a destructive confirmation, branch
# name validation, and the delete-menu exclusions. Mirrors the RoadmapParser /
# FeedbackRouting / Recipes standalone-test pattern.
#
# Usage: scripts/git-branch-ops-test.sh   (run from the repo root)
# Exit: 0 all pass, 1 an assertion failed, 64 compile failure.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DRIVER="$(mktemp -t git-branch-ops-test)"
trap 'rm -f "$DRIVER"' EXIT

echo "==> Compiling branch-actions logic test"
if ! swiftc -O \
    "$ROOT/swift/Sources/suit/GitBranchOps.swift" \
    "$ROOT/scripts/git-branch-ops-test/main.swift" \
    -o "$DRIVER"; then
    echo "COMPILE FAILED"
    exit 64
fi

echo "==> Running"
"$DRIVER"
