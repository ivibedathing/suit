#!/bin/bash
# Commit-graph layout harness (ROADMAP Phase 34). Builds a throwaway fixture
# git repo with a fork and a merge (deterministic commit dates for a stable
# order), captures `git log` in the exact format the pane uses, then compiles
# the real CommitGraph.swift against the assertion driver in
# scripts/commit-graph-harness/main.swift and feeds it the log. No app, no UI —
# just the lane assignment, edges, and ref badges the phase's verification
# calls out. Exits nonzero on any failed assertion.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
src="$root/swift/Sources/suit"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- Build the fixture repo -------------------------------------------------
repo="$tmp/repo"
mkdir -p "$repo"
git -C "$repo" init -q -b main
git -C "$repo" config user.email t@t.t
git -C "$repo" config user.name tester

commit() { # $1 = subject, $2 = epoch date
  echo "$1" > "$repo/$1.txt"
  git -C "$repo" add -A
  GIT_AUTHOR_DATE="$2 +0000" GIT_COMMITTER_DATE="$2 +0000" \
    git -C "$repo" commit -q -m "$1"
}

commit root   1700000001
git -C "$repo" tag v1.0
commit second 1700000002
# Fork: feature branches off second.
git -C "$repo" branch feature
commit main-c 1700000003          # advances main
git -C "$repo" checkout -q feature
commit feat-d 1700000004          # advances feature
git -C "$repo" checkout -q main
# Merge feature into main (first parent = main-c, second = feat-d).
GIT_AUTHOR_DATE="1700000005 +0000" GIT_COMMITTER_DATE="1700000005 +0000" \
  git -C "$repo" merge --no-ff -q -m "merge-m" feature

# --- Capture the log in the pane's format -----------------------------------
git -C "$repo" log --all --date-order \
  --pretty=format:'%H%x1f%P%x1f%an%x1f%at%x1f%D%x1f%s%x1e' > "$tmp/log.txt"

# --- Compile the pure core + driver, run -------------------------------------
swiftc -O \
  "$src/CommitGraph.swift" \
  "$root/scripts/commit-graph-harness/main.swift" \
  -o "$tmp/harness"

"$tmp/harness" "$tmp/log.txt"
