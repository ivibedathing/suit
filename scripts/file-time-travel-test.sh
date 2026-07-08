#!/bin/bash
# File time-travel scrubber logic test (ROADMAP Phase 40): builds a throwaway
# fixture git repo with a file whose lines change across three commits plus an
# uncommitted working-tree edit, captures `git log --follow` in GitFileHistory's
# format, then compiles the real (Foundation-only) FileTimeTravel.swift against
# the assertion driver in scripts/file-time-travel-test/main.swift and feeds it
# the repo. The driver asserts the timeline shape, per-position content (via the
# real `git show` argv), diff-to-neighbour changed lines, working-tree restore,
# the hunk parser, and header labels. No app, no UI.
#
# Usage: scripts/file-time-travel-test.sh   (run from the repo root)
# Exit: 0 all pass, 1 an assertion failed, 64 compile failure.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- Build the fixture repo -------------------------------------------------
REPO="$TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@t.t
git -C "$REPO" config user.name tester

commit_at() { # $1 = epoch date, $2 = message
  git -C "$REPO" add -A
  GIT_AUTHOR_DATE="$1 +0000" GIT_COMMITTER_DATE="$1 +0000" \
    git -C "$REPO" commit -q -m "$2"
}

# c1: three lines.
printf 'line1\nline2\nline3\n' > "$REPO/foo.txt"
commit_at 1600000001 "add foo"
# c2: line 2 changes.
printf 'line1\nline2-changed\nline3\n' > "$REPO/foo.txt"
commit_at 1600000002 "edit line two"
# c3 (HEAD): append line 4.
printf 'line1\nline2-changed\nline3\nline4\n' > "$REPO/foo.txt"
commit_at 1600000003 "append line four"
# Working tree: line 1 changes, uncommitted.
printf 'line1-wt\nline2-changed\nline3\nline4\n' > "$REPO/foo.txt"

# --- Per-position expected content (oldest → newest → working tree) ----------
EXP="$TMP/expected"
mkdir -p "$EXP"
printf 'line1\nline2\nline3\n'                 > "$EXP/pos0.expected"
printf 'line1\nline2-changed\nline3\n'         > "$EXP/pos1.expected"
printf 'line1\nline2-changed\nline3\nline4\n'  > "$EXP/pos2.expected"
printf 'line1-wt\nline2-changed\nline3\nline4\n' > "$EXP/pos3.expected"

# --- Capture the log in GitFileHistory's format -----------------------------
git -C "$REPO" log --follow --format='%H%x1f%h%x1f%an%x1f%at%x1f%s' -- foo.txt > "$TMP/log.txt"

# --- Compile the pure core + driver, run ------------------------------------
echo "==> Compiling file time-travel logic test"
if ! swiftc -O \
    "$ROOT/swift/Sources/suit/FileTimeTravel.swift" \
    "$ROOT/scripts/file-time-travel-test/main.swift" \
    -o "$TMP/harness"; then
    echo "COMPILE FAILED"
    exit 64
fi

echo "==> Running"
"$TMP/harness" "$REPO" "foo.txt" "$TMP/log.txt" "$EXP"
