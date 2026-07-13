#!/bin/bash
# Shell-helpers (run_silent) logic test: compiles the UI-free core
# (swift/Sources/suit/ShellInjection.swift, Foundation-only, no app deps) with
# scripts/shell-extras-test/main.swift and runs its env-construction
# assertions, then exercises the real artifacts — the ZDOTDIR shim files and
# suit-shell-extras.zsh — with an actual zsh in a scratch HOME: the user's own
# rc files still run, run_silent prints only ✓ on success and everything on
# failure, the load guard survives nested shells, and a missing extras file
# breaks nothing. Mirrors the rtk-test two-part pattern.
#
# Usage: scripts/shell-extras-test.sh   (run from the repo root)
# Exit: 0 all pass, 1 an assertion failed, 64 compile failure.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DRIVER="$(mktemp -t shell-extras-test)"
SCRATCH="$(mktemp -d -t shell-extras)"
trap 'rm -f "$DRIVER"; rm -rf "$SCRATCH"' EXIT

echo "==> Compiling shell-injection logic test"
if ! swiftc -O \
    "$ROOT/swift/Sources/suit/ShellInjection.swift" \
    "$ROOT/scripts/shell-extras-test/main.swift" \
    -o "$DRIVER"; then
    echo "COMPILE FAILED"
    exit 64
fi

echo "==> Running core assertions"
"$DRIVER"

# --- Shim + extras assertions (a real zsh in a scratch HOME) ------------------
echo "==> Running zsh shim assertions"
command -v zsh >/dev/null 2>&1 || { echo "SKIP: zsh not found"; exit 0; }

fail=0
scheck() { # <condition-bool> <message>
  if [ "$1" = "1" ]; then echo "  ok: $2"; else echo "  FAIL: $2"; fail=$((fail + 1)); fi
}

# A scratch HOME with a marker .zshrc, the shim installed as the app would.
DHOME="$SCRATCH/home"
mkdir -p "$DHOME/.suit/zsh" "$DHOME/.suit/scripts"
printf 'export USER_RC_RAN=1\n' >"$DHOME/.zshrc"
cp "$ROOT"/scripts/claude/suit-zdotdir/.zshenv "$ROOT"/scripts/claude/suit-zdotdir/.zprofile \
   "$ROOT"/scripts/claude/suit-zdotdir/.zshrc "$ROOT"/scripts/claude/suit-zdotdir/.zlogin \
   "$DHOME/.suit/zsh/"
cp "$ROOT/scripts/claude/suit-shell-extras.zsh" "$DHOME/.suit/scripts/"

# Launch zsh the way Suit does: ZDOTDIR at the shim, the user chain + extras
# passed through the env. -i so .zshrc runs (like the app's -l -i, minus -l to
# keep the sandbox clear of the machine's real login files).
run_zsh() {
  HOME="$DHOME" ZDOTDIR="$DHOME/.suit/zsh" \
  SUIT_USER_ZDOTDIR="$DHOME" \
  SUIT_SHELL_EXTRAS="$DHOME/.suit/scripts/suit-shell-extras.zsh" \
  zsh -i -c "$1" 2>&1
}

out="$(run_zsh 'echo "rc=$USER_RC_RAN extras=$SUIT_EXTRAS_LOADED"')"
scheck "$(printf '%s' "$out" | grep -q 'rc=1 extras=1' && echo 1 || echo 0)" \
  "the user's .zshrc runs and the extras load"

out="$(run_zsh 'run_silent true')"
scheck "$(printf '%s' "$out" | grep -q '^✓ true' && echo 1 || echo 0)" \
  "run_silent true prints only the ✓ line"
scheck "$([ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "1" ] && echo 1 || echo 0)" \
  "a passing run is exactly one line"

out="$(run_zsh 'run_silent sh -c "echo boom; exit 3"; echo "rc=$?"')"
scheck "$(printf '%s' "$out" | grep -q 'boom' && echo 1 || echo 0)" \
  "a failing run prints its full output"
scheck "$(printf '%s' "$out" | grep -q '✗ sh -c echo boom; exit 3 (exit 3' && echo 1 || echo 0)" \
  "the ✗ line carries the exit code"
scheck "$(printf '%s' "$out" | grep -q 'rc=3' && echo 1 || echo 0)" \
  "run_silent propagates the exit code"

# The guard is per-shell (not exported): a nested zsh sources its own copy of
# the extras, so run_silent exists there too; within one shell a re-source of
# .zshrc stays a no-op.
out="$(run_zsh 'zsh -i -c "whence -w run_silent"')"
scheck "$(printf '%s' "$out" | grep -q 'run_silent: function' && echo 1 || echo 0)" \
  "a nested zsh still has run_silent"
out="$(run_zsh '. "$ZDOTDIR/.zshrc"; whence -w run_silent; echo resourced-ok')"
scheck "$(printf '%s' "$out" | grep -q 'resourced-ok' && echo 1 || echo 0)" \
  "re-sourcing .zshrc in the same shell is harmless"

# A user .zshenv that re-points ZDOTDIR (framework pattern): its config chain
# is followed, the extras still load.
mkdir -p "$DHOME/.config/zsh"
printf 'export FRAMEWORK_RC_RAN=1\n' >"$DHOME/.config/zsh/.zshrc"
printf 'export ZDOTDIR="$HOME/.config/zsh"\n' >"$DHOME/.zshenv"
out="$(run_zsh 'echo "fw=$FRAMEWORK_RC_RAN extras=$SUIT_EXTRAS_LOADED"')"
scheck "$(printf '%s' "$out" | grep -q 'fw=1 extras=1' && echo 1 || echo 0)" \
  "a user .zshenv that re-points ZDOTDIR still gets its rc and the extras"
rm -f "$DHOME/.zshenv"; rm -rf "$DHOME/.config"

# Without the extras file the shell still starts and the user rc still runs.
rm -f "$DHOME/.suit/scripts/suit-shell-extras.zsh"
out="$(run_zsh 'echo "rc=$USER_RC_RAN extras=${SUIT_EXTRAS_LOADED:-none}"')"
scheck "$(printf '%s' "$out" | grep -q 'rc=1 extras=none' && echo 1 || echo 0)" \
  "a missing extras file degrades to a plain shell"

if [ "$fail" -gt 0 ]; then
  echo "$fail SHIM FAILURE(S)"
  exit 1
fi
echo "ALL PASS"
