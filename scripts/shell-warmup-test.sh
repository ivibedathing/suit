#!/bin/bash
# Shell warm-up typeahead test: compiles the UI-free gate
# (swift/Sources/suit/ShellWarmup.swift — Foundation-only, no app deps) with
# scripts/shell-warmup-test/main.swift and runs its assertions: the tty-mode
# mapping that decides when the gate is armed (checked against a real pty pair,
# since the design rests on a master fd reporting the slave's line discipline),
# local echo and backspace, escape sequences, ^C/^U/Return, wide and partial
# UTF-8, and the flush that hands zle the line. Mirrors the editor-ops /
# find-replace standalone-test pattern.
#
# Usage: scripts/shell-warmup-test.sh   (run from the repo root)
# Exit: 0 all pass, 1 an assertion failed, 64 compile failure.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DRIVER="$(mktemp -t shell-warmup-test)"
trap 'rm -f "$DRIVER"' EXIT

echo "==> Compiling shell-warmup logic test"
if ! swiftc -O \
    "$ROOT/swift/Sources/suit/ShellWarmup.swift" \
    "$ROOT/scripts/shell-warmup-test/main.swift" \
    -o "$DRIVER"; then
    echo "COMPILE FAILED"
    exit 64
fi

echo "==> Running"
"$DRIVER"
