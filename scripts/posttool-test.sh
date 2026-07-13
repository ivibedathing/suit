#!/bin/bash
# PostToolUse output-filter logic test: compiles the UI-free core
# (swift/Sources/suit/PostToolHook.swift, Foundation-only, no app deps) with
# scripts/posttool-test/main.swift and runs its assertions — the settings.json
# transform that wires the dispatcher hook set (PostToolUse + the dedup
# lifecycle events) in and out, idempotently, rewriting flags in place and
# preserving every unrelated key and hook — then exercises the hook script
# itself (scripts/claude/suit-posttool-filter.sh): giant results are elided
# with head and tail intact, small results and every error path pass through.
# Mirrors the rtk-test two-part pattern.
#
# Usage: scripts/posttool-test.sh   (run from the repo root)
# Exit: 0 all pass, 1 an assertion failed, 64 compile failure.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DRIVER="$(mktemp -t posttool-test)"
trap 'rm -f "$DRIVER"' EXIT

echo "==> Compiling post-tool hook logic test"
if ! swiftc -O \
    "$ROOT/swift/Sources/suit/PostToolHook.swift" \
    "$ROOT/scripts/posttool-test/main.swift" \
    -o "$DRIVER"; then
    echo "COMPILE FAILED"
    exit 64
fi

echo "==> Running core assertions"
"$DRIVER"

# --- Hook-script assertions (the runtime artifact, not the Swift core) --------
echo "==> Running hook-script assertions"
HOOK="$ROOT/scripts/claude/suit-posttool-filter.sh"
SCRATCH="$(mktemp -d -t posttool-hook)"
trap 'rm -f "$DRIVER"; rm -rf "$SCRATCH"' EXIT

hook_fail=0
hcheck() { # <condition-bool> <message>
  if [ "$1" = "1" ]; then echo "  ok: $2"; else echo "  FAIL: $2"; hook_fail=$((hook_fail + 1)); fi
}
nonempty() { [ -n "$1" ] && echo 1 || echo 0; }
empty() { [ -z "$1" ] && echo 1 || echo 0; }

# Build fixtures with jq so giant strings embed as valid JSON.
BIG_LINES="$(jq -n '[range(0; 2000)] | map("line " + (. | tostring) + ": some grep match content that pads the row out") | join("\n")')"
BIG_BLOB="$(jq -n '"x" * 60000')"
SMALL='"just a few lines\nof ordinary output"'

# payload <tool_name> <tool_response-json> [tool_input-json]
payload() {
  local ti="${3:-}"
  [ -n "$ti" ] || ti='{}'
  printf '{"session_id":"s1","hook_event_name":"PostToolUse","tool_name":"%s","tool_input":%s,"tool_response":%s}' \
    "$1" "$ti" "$2"
}

run_hook() { bash "$HOOK" --compress; }

out="$(payload Grep "$BIG_LINES" | run_hook)"
hcheck "$(nonempty "$out")" "a giant line-shaped Grep result is rewritten"
hcheck "$(printf '%s' "$out" | jq -e '.hookSpecificOutput.updatedToolOutput' >/dev/null 2>&1 && echo 1 || echo 0)" \
  "the rewrite is a well-formed updatedToolOutput payload"
REPL="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.updatedToolOutput')"
hcheck "$(printf '%s' "$REPL" | grep -q 'line 0:' && echo 1 || echo 0)" "the head survives the elision"
hcheck "$(printf '%s' "$REPL" | grep -q 'line 1999:' && echo 1 || echo 0)" "the tail survives the elision"
hcheck "$(printf '%s' "$REPL" | grep -q '\[suit: elided' && echo 1 || echo 0)" "the elision marker is present"
hcheck "$([ "${#REPL}" -lt "${#BIG_LINES}" ] && echo 1 || echo 0)" "the replacement is smaller than the original"

out="$(payload Read "$BIG_BLOB" | run_hook)"
hcheck "$(nonempty "$out")" "a giant single-blob Read result is rewritten (byte cut)"

BIG_GLOB="$(jq -n '{filenames: ([range(0; 1500)] | map("/repo/src/deeply/nested/dir/file-" + (. | tostring) + ".swift")), numFiles: 1500}')"
out="$(payload Glob "$BIG_GLOB" | run_hook)"
hcheck "$(nonempty "$out")" "a giant Glob filenames array is rewritten"

out="$(payload Bash "{\"stdout\":$BIG_BLOB,\"stderr\":\"boom failed\"}" '{"command":"npm test"}' | run_hook)"
hcheck "$(nonempty "$out")" "an object-shaped Bash result (stdout/stderr) is rewritten"
hcheck "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.updatedToolOutput' | grep -q 'boom failed' && echo 1 || echo 0)" \
  "the Bash stderr survives in the replacement"

hcheck "$(empty "$(payload Read "$SMALL" | run_hook)")" "a small result passes through untouched"
hcheck "$(empty "$(payload Bash "$BIG_BLOB" '{"command":"rtk git status"}' | run_hook)")" \
  "an rtk-wrapped Bash command passes through (no double-processing)"
hcheck "$(empty "$(payload Bash "$BIG_BLOB" '{"command":"npm test # nortk"}' | run_hook)")" \
  "'# nortk' opts a command out of post-filtering too"
hcheck "$(empty "$(payload Edit "$BIG_BLOB" | run_hook)")" "an unmatched tool passes through"
hcheck "$(empty "$(payload Grep '{"weird":"shape"}' | run_hook)")" "an unrecognized response shape passes through"
hcheck "$(empty "$(printf 'not json' | run_hook)")" "malformed input passes through"
hcheck "$(empty "$(printf '' | run_hook)")" "empty input passes through"
hcheck "$(empty "$(payload Grep "$BIG_LINES" | bash "$HOOK")")" "no --compress flag → pass through"
# The no-jq hook exits before reading stdin; feed it from a file so the test
# script's own printf can't die of SIGPIPE (pipefail would surface the 141).
payload Grep "$BIG_LINES" >"$SCRATCH/payload.json"
hcheck "$(empty "$(PATH=/nonexistent /bin/bash "$HOOK" --compress <"$SCRATCH/payload.json")")" \
  "no jq on PATH → pass through"

payload Grep "$BIG_LINES" | run_hook >/dev/null
hcheck "$([ $? -eq 0 ] && echo 1 || echo 0)" "hook exits 0"
PATH=/nonexistent /bin/bash "$HOOK" --compress <"$SCRATCH/payload.json" >/dev/null 2>&1
hcheck "$([ $? -eq 0 ] && echo 1 || echo 0)" "hook exits 0 even without jq"

if [ "$hook_fail" -gt 0 ]; then
  echo "$hook_fail HOOK-SCRIPT FAILURE(S)"
  exit 1
fi
echo "ALL PASS"
