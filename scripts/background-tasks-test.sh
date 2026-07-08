#!/bin/bash
# Background-task monitor test (ROADMAP Phase 30): compiles the UI-free core
# (swift/Sources/suit/BackgroundTasks.swift, Foundation-only, no app deps) with
# scripts/background-tasks-test/main.swift and runs its assertions — the pure
# status reconciliation, the strip-attention transition signal, the lsof port
# parser, process-subtree membership, and the incremental log tail.
#
# It then exercises the real scripts/suit-bg.sh wrapper end-to-end: starts three
# known background processes (one long-lived, one that exits clean, one that
# fails) into a sandboxed $HOME, waits for the short ones to finish, and hands
# the resulting records back to the compiled driver ($SUIT_TASKS_DIR) which
# resolves each against live process state and asserts the status — plus checks
# the wrapper captured a job's stdout to its log and tails a second line.
#
# Usage: scripts/background-tasks-test.sh   (run from the repo root)
# Exit: 0 all pass, 1 an assertion failed, 64 compile failure.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DRIVER="$(mktemp -t background-tasks-test)"
SANDBOX="$(mktemp -d -t suit-bgtasks-home)"
trap 'rm -f "$DRIVER"; [ -n "${LONG_PID:-}" ] && kill "$LONG_PID" 2>/dev/null; rm -rf "$SANDBOX"' EXIT

echo "==> Compiling background-task logic test"
if ! swiftc -O \
    "$ROOT/swift/Sources/suit/BackgroundTasks.swift" \
    "$ROOT/scripts/background-tasks-test/main.swift" \
    -o "$DRIVER"; then
    echo "COMPILE FAILED"
    exit 64
fi

echo "==> Starting known background processes through scripts/suit-bg.sh"
TASKS_DIR="$SANDBOX/.suit/tasks"
# Long-lived, clean-exit, and failing jobs — the wrapper marks each record's
# command with a unique word the driver keys on. The clean job also emits two
# log lines a beat apart so we can check the wrapper captured + appended output.
HOME="$SANDBOX" bash "$ROOT/scripts/suit-bg.sh" sh -c 'echo LONGLIVED; sleep 30' >/dev/null
HOME="$SANDBOX" bash "$ROOT/scripts/suit-bg.sh" sh -c 'echo CLEANEXIT-line1; sleep 1; echo CLEANEXIT-line2; exit 0' >/dev/null
HOME="$SANDBOX" bash "$ROOT/scripts/suit-bg.sh" sh -c 'echo FAILEXIT; exit 3' >/dev/null

# Let the failing + first log line land.
sleep 1
CLEAN_LOG="$(grep -l CLEANEXIT "$TASKS_DIR"/*.json | head -1 | sed 's/\.json$/.log/')"
if [ -f "$CLEAN_LOG" ] && grep -q "CLEANEXIT-line1" "$CLEAN_LOG"; then
    echo "PASS: wrapper captured stdout to the log (line1)"
else
    echo "FAIL: wrapper captured stdout to the log (line1)"; FAIL=1
fi

# Wait for the clean job's second line + its clean exit to be recorded.
sleep 2
if grep -q "CLEANEXIT-line2" "$CLEAN_LOG"; then
    echo "PASS: log tail picked up the appended second line"
else
    echo "FAIL: log tail picked up the appended second line"; FAIL=1
fi

# Track the long-lived pid so the trap can reap it.
LONG_REC="$(grep -l LONGLIVED "$TASKS_DIR"/*.json | head -1)"
LONG_PID="$(sed -E 's/.*"pid":([0-9]+).*/\1/' "$LONG_REC")"

echo "==> Resolving on-disk records against live process state"
SUIT_TASKS_DIR="$TASKS_DIR" "$DRIVER"
DRIVER_STATUS=$?

if [ -n "${FAIL:-}" ] || [ "$DRIVER_STATUS" -ne 0 ]; then
    echo "SOME TESTS FAILED"
    exit 1
fi
echo "All background-task tests passed."
