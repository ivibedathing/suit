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

# All hook invocations run against a scratch HOME so the savings meter (and
# anything else under ~/.suit) never touches the real home.
HHOME="$SCRATCH/home"
mkdir -p "$HHOME"
run_hook() { HOME="$HHOME" bash "$HOOK" --compress; }

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

# --- Read-dedup assertions (scratch HOME so the cache is sandboxed) -----------
echo "==> Running read-dedup assertions"
DHOME="$SCRATCH/home"
mkdir -p "$DHOME"
TARGET="$SCRATCH/target.swift"
printf 'line one\nline two\nline three\n' >"$TARGET"
CACHEFILE="$DHOME/.suit/read-cache/sdedup.json"

# read_payload [tool_input-extras-json]
read_payload() {
  local extra="${1:-}"
  printf '{"session_id":"sdedup","hook_event_name":"PostToolUse","tool_name":"Read","tool_input":{"file_path":"%s"%s},"tool_response":{"type":"text","file":{"filePath":"%s","content":"line one\\nline two\\nline three"}}}' \
    "$TARGET" "$extra" "$TARGET"
}
dedup_hook() { HOME="$DHOME" bash "$HOOK" --dedup; }

hcheck "$(empty "$(read_payload | dedup_hook)")" "first read passes through"
hcheck "$([ -f "$CACHEFILE" ] && echo 1 || echo 0)" "first read records a cache entry"
hcheck "$(HOME="$DHOME" jq -r --arg f "$TARGET" '.files[$f].stubbed' "$CACHEFILE" | grep -q false && echo 1 || echo 0)" \
  "the fresh entry is not stubbed"

out="$(read_payload | dedup_hook)"
hcheck "$(nonempty "$out")" "a repeat read of the unchanged file is stubbed"
hcheck "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.updatedToolOutput' | grep -q 'read-dedup' && echo 1 || echo 0)" \
  "the stub names itself and the recovery path"
hcheck "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.updatedToolOutput' | grep -q '3 lines' && echo 1 || echo 0)" \
  "the stub reports the file's line count"
hcheck "$(jq -r --arg f "$TARGET" '.files[$f].stubbed' "$CACHEFILE" | grep -q true && echo 1 || echo 0)" \
  "the entry is marked stubbed"

hcheck "$(empty "$(read_payload | dedup_hook)")" "the next read passes the full content (stub-once)"
hcheck "$(jq -r --arg f "$TARGET" '.files[$f].stubbed' "$CACHEFILE" | grep -q false && echo 1 || echo 0)" \
  "the loop breaker re-arms the entry"
hcheck "$(nonempty "$(read_payload | dedup_hook)")" "a fourth read is stubbed again"

# Any edit (mtime or size change) forces a real re-read.
printf 'line one\nline two\nline three\nline four\n' >"$TARGET"
hcheck "$(empty "$(read_payload | dedup_hook)")" "an edited file re-reads fully"
hcheck "$(jq -r --arg f "$TARGET" '.files[$f].lines' "$CACHEFILE" | grep -q 4 && echo 1 || echo 0)" \
  "the entry re-records the new state"
# mtime-only change (same byte size): still a re-read.
hcheck "$(nonempty "$(read_payload | dedup_hook)")" "(setup) unchanged again → stubbed"
hcheck "$(empty "$(read_payload | dedup_hook)")" "(setup) stub-once passes through"
touch -t 202601010101 "$TARGET"
hcheck "$(empty "$(read_payload | dedup_hook)")" "an mtime-only change re-reads fully"

# Range reads never participate.
hcheck "$(nonempty "$(read_payload | dedup_hook)")" "(setup) whole file stubbed again"
hcheck "$(empty "$(read_payload ',"offset":10,"limit":20' | dedup_hook)")" \
  "an offset/limit read passes through even while stubbed"
hcheck "$(jq -r --arg f "$TARGET" '.files[$f].stubbed' "$CACHEFILE" | grep -q true && echo 1 || echo 0)" \
  "a range read leaves the cache entry untouched"

# Lifecycle: PreCompact clears, SessionEnd deletes.
printf '{"session_id":"sdedup","hook_event_name":"PreCompact"}' | HOME="$DHOME" bash "$HOOK" --clear-cache
hcheck "$(jq -r '.files | length' "$CACHEFILE" | grep -q '^0$' && echo 1 || echo 0)" \
  "--clear-cache empties the session's entries"
printf '{"session_id":"sdedup","hook_event_name":"SessionEnd"}' | HOME="$DHOME" bash "$HOOK" --end-session
hcheck "$([ ! -f "$CACHEFILE" ] && echo 1 || echo 0)" "--end-session deletes the cache file"

# Dedup without the flag, or for a missing file, never touches anything.
hcheck "$(empty "$(read_payload | HOME="$DHOME" bash "$HOOK" --compress)")" \
  "no --dedup flag → a repeat read passes through"
rm -f "$TARGET"
hcheck "$(empty "$(read_payload | dedup_hook)")" "a vanished file passes through"

# --- Savings-meter & kill-switch assertions (fresh scratch HOME) ---------------
echo "==> Running savings-meter assertions"
MHOME="$SCRATCH/mhome"
mkdir -p "$MHOME"
MLOG="$MHOME/.suit/token-savings.jsonl"
mhook() { HOME="$MHOME" bash "$HOOK" "$@"; }

payload Grep "$BIG_LINES" | mhook --compress >/dev/null
hcheck "$([ -f "$MLOG" ] && echo 1 || echo 0)" "a compress rewrite appends a savings-meter line"
hcheck "$(jq -e 'select(.kind == "compress" and .tool == "Grep"
                 and .original_chars > .emitted_chars and .session_id == "s1")' \
          "$MLOG" >/dev/null 2>&1 && echo 1 || echo 0)" \
  "the line records kind/tool/session and a genuine shrink"

hcheck "$(empty "$(payload Read "$SMALL" | mhook --compress)")" "(setup) small result passes through"
hcheck "$([ "$(wc -l <"$MLOG" | tr -d ' ')" = "1" ] && echo 1 || echo 0)" \
  "a pass-through logs nothing"

out="$(payload Grep "$BIG_LINES" | SUIT_SAVINGS_LOG=0 mhook --compress)"
hcheck "$(nonempty "$out")" "SUIT_SAVINGS_LOG=0 still rewrites"
hcheck "$([ "$(wc -l <"$MLOG" | tr -d ' ')" = "1" ] && echo 1 || echo 0)" \
  "SUIT_SAVINGS_LOG=0 skips the meter"

# A dedup stub logs its counterfactual too (original content vs stub size).
printf 'line one\nline two\nline three\n' >"$TARGET"
read_payload | HOME="$MHOME" bash "$HOOK" --dedup >/dev/null
out="$(read_payload | HOME="$MHOME" bash "$HOOK" --dedup)"
hcheck "$(nonempty "$out")" "(setup) repeat read is stubbed"
# (On this tiny fixture the stub is longer than the file — the meter records
# the negative saving truthfully; only the counterfactual fields are asserted.)
hcheck "$(jq -es '[.[] | select(.kind == "dedup" and .tool == "Read"
                  and .original_chars > 0 and .emitted_chars > 0)] | length == 1' \
          "$MLOG" >/dev/null 2>&1 && echo 1 || echo 0)" \
  "the stub logs a dedup savings line"

# Kill-switch: SUIT_TOKEN_FILTERS=off makes every mode a pure pass-through.
hcheck "$(empty "$(payload Grep "$BIG_LINES" | SUIT_TOKEN_FILTERS=off mhook --compress)")" \
  "SUIT_TOKEN_FILTERS=off → compress passes through"
printf 'line one\nline two\nline three\n' >"$TARGET"
read_payload | HOME="$MHOME" bash "$HOOK" --dedup >/dev/null
hcheck "$(empty "$(read_payload | SUIT_TOKEN_FILTERS=off HOME="$MHOME" bash "$HOOK" --dedup)")" \
  "SUIT_TOKEN_FILTERS=off → dedup passes through"
rm -f "$TARGET"

if [ "$hook_fail" -gt 0 ]; then
  echo "$hook_fail HOOK-SCRIPT FAILURE(S)"
  exit 1
fi
echo "ALL PASS"
