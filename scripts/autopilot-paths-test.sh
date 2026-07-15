#!/bin/bash
# AutopilotPaths logic test: compiles the UI-free core
# (swift/Sources/suit/AutopilotPaths.swift, Foundation-only, no app deps) with
# scripts/autopilot-paths-test/main.swift and runs its assertions — root
# normalization (tilde, trailing slashes, and the /private carve-out that keeps
# worker session pinning working), component-anchored containment (so /tmp/repo
# never swallows /tmp/repo-two), and the longest-match root lookup behind the
# terminal context menu's Start/Stop Autopilot item (nested repos, task
# worktrees). Mirrors the RoadmapParser / UpdateCheckCore standalone-test
# pattern.
#
# Usage: scripts/autopilot-paths-test.sh   (run from the repo root)
# Exit: 0 all pass, 1 an assertion failed, 64 compile failure.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DRIVER="$(mktemp -t autopilot-paths-test)"
trap 'rm -f "$DRIVER"' EXIT

echo "==> Compiling AutopilotPaths logic test"
if ! swiftc -O \
    "$ROOT/swift/Sources/suit/AutopilotPaths.swift" \
    "$ROOT/scripts/autopilot-paths-test/main.swift" \
    -o "$DRIVER"; then
    echo "COMPILE FAILED"
    exit 64
fi

echo "==> Running"
"$DRIVER"
