#!/bin/bash
# Source Control refresh-gate test: asserts that the Git tab's shelling-out
# passes (branch list, feedback gather, the two `gh pr list` calls) stay idle
# while the tab is hidden and while files merely churn, and that the rows still
# track the working tree — including edits to files git already tracks, which
# change `git status` without changing the file index's list of paths.
#
# Slow (~40 s): unlike the other harnesses this compiles the whole app, because
# what is under test is the wiring between FSEvents, FileIndex,
# GitStatusMonitor, SidebarView and GitView. It drives the real AppDelegate
# offscreen, the way design/reference/main.swift does.
#
# Everything is sandboxed: a scratch $HOME (so ~/.suit is never touched), a
# scratch git repo, and a `gh` stub on SUIT_GH_PATH that logs its calls and
# returns "[]" — so the run is offline and "how many times did we shell out to
# gh" is a hard count rather than something inferred from timing.
#
# Usage: scripts/source-control-gate-test.sh   (run from the repo root)
# Exit: 0 all pass, 1 an assertion failed, 64 compile failure.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
WORK="$(mktemp -d -t suit-scgate)"
trap 'rm -rf "$WORK"' EXIT

# --- fixture: a small repo with ignored build / worktree trees ---------------
REPO="$WORK/repo"
mkdir -p "$REPO/src" "$REPO/build" "$REPO/.claude/worktrees/other"
mkdir -p "$WORK/home/.suit/sessions"
printf 'build/\n.claude/worktrees/\n' > "$REPO/.gitignore"
for i in $(seq 1 40); do
    printf 'let value%d = %d\n' "$i" "$i" > "$REPO/src/file$i.swift"
done
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name "Suit Test"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "initial"
# Pre-populate the ignored trees so the first scan already knows they are
# ignored — the state a real checkout is in a second after launch.
for i in $(seq 1 20); do
    printf 'obj%d\n' "$i" > "$REPO/build/obj$i.o"
    printf 'x\n' > "$REPO/.claude/worktrees/other/f$i.txt"
done

# --- gh stub ----------------------------------------------------------------
GHLOG="$WORK/gh-calls.log"
: > "$GHLOG"
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<STUB
#!/bin/bash
echo "\$@" >> "$GHLOG"
echo "[]"
STUB
chmod +x "$WORK/bin/gh"

DRIVER="$WORK/driver"

echo "==> Compiling source-control gate test (whole app — this is the slow one)"
# The app's own main.swift is excluded: the driver supplies the entry point.
if ! swiftc -Onone -j "$(sysctl -n hw.ncpu 2>/dev/null || echo 4)" \
    $(ls "$ROOT"/swift/Sources/suit/*.swift | grep -v '/main.swift$') \
    "$ROOT/scripts/source-control-gate-test/main.swift" \
    $(find "$ROOT/swift/Vendor/SwiftTerm" -name '*.swift') \
    -o "$DRIVER"; then
    echo "COMPILE FAILED"
    exit 64
fi

echo "==> Running"
cd "$REPO"
HOME="$WORK/home" SUIT_GH_PATH="$WORK/bin/gh" "$DRIVER" "$REPO" "$GHLOG"
