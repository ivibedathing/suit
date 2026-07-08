#!/bin/bash
# Isolation + subagent-tree logic harness (ROADMAP Phase 31). Compiles the real
# TaskLaunch.swift (the per-task isolation decision) and SubagentTree.swift (the
# session-anchored nesting/pruning core) against the assertion driver in
# scripts/isolation-harness/main.swift, then runs it. Both files are
# Foundation-only, so no stub is needed. No app, no UI — just the checkout
# decision and the tree nesting/pruning the phase's verification calls out.
# Exits nonzero on any failed assertion.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
src="$root/swift/Sources/suit"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

swiftc -O \
  "$src/TaskLaunch.swift" \
  "$src/SubagentTree.swift" \
  "$root/scripts/isolation-harness/main.swift" \
  -o "$tmp/harness"

"$tmp/harness"
