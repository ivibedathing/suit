#!/bin/bash
# rtk output-compression hook logic test: compiles the UI-free core
# (swift/Sources/suit/RtkHook.swift, Foundation-only, no app deps) with
# scripts/rtk-test/main.swift and runs its assertions — the settings.json
# transform that wires the rtk PreToolUse hook in and out, idempotently,
# preserving every unrelated key and hook. Mirrors the RoadmapParser /
# Recipes / FeedbackRouting standalone-test pattern.
#
# Usage: scripts/rtk-test.sh   (run from the repo root)
# Exit: 0 all pass, 1 an assertion failed, 64 compile failure.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DRIVER="$(mktemp -t rtk-test)"
trap 'rm -f "$DRIVER"' EXIT

echo "==> Compiling rtk hook logic test"
if ! swiftc -O \
    "$ROOT/swift/Sources/suit/RtkHook.swift" \
    "$ROOT/scripts/rtk-test/main.swift" \
    -o "$DRIVER"; then
    echo "COMPILE FAILED"
    exit 64
fi

echo "==> Running core assertions"
"$DRIVER"

# --- Hook-script assertions (the runtime artifact, not the Swift core) --------
# Exercise scripts/claude/suit-rtk-rewrite.sh directly: it must wrap a normal
# command through rtk, and pass through (empty output, exit 0) whenever rtk is
# missing, the command is already wrapped, or a bypass marker is present.
echo "==> Running hook-script assertions"
HOOK="$ROOT/scripts/claude/suit-rtk-rewrite.sh"
SCRATCH="$(mktemp -d -t rtk-hook)"
trap 'rm -f "$DRIVER"; rm -rf "$SCRATCH"' EXIT
printf '#!/bin/sh\necho fake\n' > "$SCRATCH/rtk" && chmod +x "$SCRATCH/rtk"

hook_fail=0
# run_hook <command-json-value> -> prints hook stdout, using the fake rtk on PATH
run_hook() { printf '{"tool_input":{"command":%s}}' "$1" | PATH="$SCRATCH:$PATH" bash "$HOOK"; }
run_hook_nortk() { printf '{"tool_input":{"command":%s}}' "$1" | PATH="/usr/bin:/bin" bash "$HOOK"; }
hcheck() { # <condition-bool> <message>
  if [ "$1" = "1" ]; then echo "  ok: $2"; else echo "  FAIL: $2"; hook_fail=$((hook_fail + 1)); fi
}
nonempty() { [ -n "$1" ] && echo 1 || echo 0; }
empty() { [ -z "$1" ] && echo 1 || echo 0; }

out="$(run_hook '"git status"')"
hcheck "$(nonempty "$out")" "a normal command is rewritten"
case "$out" in *'"command"'*'rtk'*'git status'*) hcheck 1 "the rewrite runs it through rtk" ;; *) hcheck 0 "the rewrite runs it through rtk" ;; esac

hcheck "$(empty "$(run_hook_nortk '"git status"')")" "no rtk on PATH -> pass through"
hcheck "$(empty "$(run_hook '"rtk git status"')")" "already-wrapped command -> pass through"
hcheck "$(empty "$(run_hook '"git status # nortk"')")" "'# nortk' marker -> pass through"
hcheck "$(empty "$(run_hook '"NO_RTK=1 npm test"')")" "'NO_RTK=1' prefix -> pass through"
hcheck "$(empty "$(run_hook '""')")" "empty command -> pass through"
hcheck "$(empty "$(printf '{"tool_input":{"command":"git status"}}' \
  | SUIT_TOKEN_FILTERS=off PATH="$SCRATCH:$PATH" bash "$HOOK")")" \
  "SUIT_TOKEN_FILTERS=off (bench kill-switch) -> pass through"

run_hook '"git status"' >/dev/null; hcheck "$([ $? -eq 0 ] && echo 1 || echo 0)" "hook exits 0"

if [ "$hook_fail" -eq 0 ]; then echo "HOOK ASSERTIONS PASS"; else echo "$hook_fail HOOK FAILURE(S)"; exit 1; fi
