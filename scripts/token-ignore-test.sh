#!/bin/bash
# Token-ignore firewall logic test: compiles the UI-free cores
# (swift/Sources/suit/TokenIgnoreHook.swift + PostToolHook.swift,
# Foundation-only, no app deps) with scripts/token-ignore-test/main.swift and
# runs its assertions — the settings.json transforms that wire the PreToolUse
# Read firewall and the dispatcher's --ignore flag in and out, idempotently —
# then exercises both hook scripts against a scratch repo carrying a
# .claude/token-ignore: full-file Reads under an ignored prefix are denied
# (range reads, non-ignored files, and every error path pass through), and
# Grep/Glob results drop ignored lines behind a count marker unless the
# search targets the path explicitly. Mirrors the rtk-test two-part pattern.
#
# Usage: scripts/token-ignore-test.sh   (run from the repo root)
# Exit: 0 all pass, 1 an assertion failed, 64 compile failure.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DRIVER="$(mktemp -t token-ignore-test)"
SCRATCH="$(mktemp -d -t token-ignore-hook)"
trap 'rm -f "$DRIVER"; rm -rf "$SCRATCH"' EXIT

echo "==> Compiling token-ignore logic test"
if ! swiftc -O \
    "$ROOT/swift/Sources/suit/TokenIgnoreHook.swift" \
    "$ROOT/swift/Sources/suit/PostToolHook.swift" \
    "$ROOT/scripts/token-ignore-test/main.swift" \
    -o "$DRIVER"; then
    echo "COMPILE FAILED"
    exit 64
fi

echo "==> Running core assertions"
"$DRIVER"

# --- Hook-script assertions (the runtime artifacts, not the Swift core) -------
echo "==> Running hook-script assertions"
FIREWALL="$ROOT/scripts/claude/suit-token-ignore.sh"
DISPATCH="$ROOT/scripts/claude/suit-posttool-filter.sh"

hook_fail=0
hcheck() { # <condition-bool> <message>
  if [ "$1" = "1" ]; then echo "  ok: $2"; else echo "  FAIL: $2"; hook_fail=$((hook_fail + 1)); fi
}
nonempty() { [ -n "$1" ] && echo 1 || echo 0; }
empty() { [ -z "$1" ] && echo 1 || echo 0; }

# Scratch repo with an ignore list, an ignored file, and a normal file. All
# hook invocations run against a scratch HOME so the savings meter never
# touches the real home.
REPO="$SCRATCH/repo"
HHOME="$SCRATCH/home"
mkdir -p "$REPO/.claude" "$REPO/vendor/lib" "$REPO/src" "$HHOME"
printf '# heavy paths\nvendor/\n' >"$REPO/.claude/token-ignore"
printf 'huge vendored blob %.0s' {1..500} >"$REPO/vendor/lib/big.txt"
printf 'ordinary source\n' >"$REPO/src/ok.txt"

# read_payload <file-path> [tool_input-extra-json]
read_payload() {
  local extra="${2:-}"
  printf '{"session_id":"s1","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"%s"%s},"cwd":"%s"}' \
    "$1" "${extra:+,$extra}" "$REPO"
}
run_firewall() { HOME="$HHOME" bash "$FIREWALL"; }

out="$(read_payload "$REPO/vendor/lib/big.txt" | run_firewall)"
hcheck "$(nonempty "$out")" "a full-file Read under an ignored prefix is intercepted"
hcheck "$(printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 && echo 1 || echo 0)" \
  "the interception is a well-formed PreToolUse deny"
hcheck "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -q 'offset/limit' && echo 1 || echo 0)" \
  "the deny reason teaches the offset/limit escape hatch"
hcheck "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -q "vendor/" && echo 1 || echo 0)" \
  "the deny reason names the matched pattern"
hcheck "$(grep -q '"kind":"ignore"' "$HHOME/.suit/token-savings.jsonl" 2>/dev/null && echo 1 || echo 0)" \
  "the deny logs an ignore-kind savings line"

hcheck "$(empty "$(read_payload "$REPO/vendor/lib/big.txt" '"offset":100,"limit":40' | run_firewall)")" \
  "a range read under the ignored prefix passes through"
hcheck "$(empty "$(read_payload "$REPO/src/ok.txt" | run_firewall)")" \
  "a non-ignored file passes through"
hcheck "$(empty "$(read_payload "$REPO/.claude/token-ignore" | run_firewall)")" \
  "the ignore list itself is always readable"
hcheck "$(empty "$(read_payload "$SCRATCH/nowhere.txt" | run_firewall)")" \
  "a path with no ignore file up-tree passes through"
hcheck "$(empty "$(read_payload "$REPO/vendor/lib/big.txt" | HOME="$HHOME" SUIT_TOKEN_FILTERS=off bash "$FIREWALL")")" \
  "SUIT_TOKEN_FILTERS=off disables the firewall"
hcheck "$(empty "$(printf 'not json' | run_firewall)")" "malformed input passes through"
hcheck "$(empty "$(printf '' | run_firewall)")" "empty input passes through"
read_payload "$REPO/vendor/lib/big.txt" >"$SCRATCH/payload.json"
hcheck "$(empty "$(PATH=/nonexistent HOME="$HHOME" /bin/bash "$FIREWALL" <"$SCRATCH/payload.json")")" \
  "no jq on PATH → pass through (fail open)"

# --- Dispatcher --ignore (Grep/Glob result filtering) --------------------------
# grep_payload <tool_name> <tool_response-json> [tool_input-json]
grep_payload() {
  local ti="${3:-}"
  [ -n "$ti" ] || ti='{}'
  printf '{"session_id":"s1","hook_event_name":"PostToolUse","tool_name":"%s","tool_input":%s,"tool_response":%s,"cwd":"%s"}' \
    "$1" "$ti" "$2" "$REPO"
}
run_ignore() { HOME="$HHOME" bash "$DISPATCH" --ignore; }

MIXED="$(jq -n --arg a "$REPO/vendor/lib/big.txt:3: vendored match" --arg b "$REPO/src/ok.txt:1: real match" \
  '{mode: "content", content: ($a + "\n" + $b), numLines: 2, numFiles: 2, filenames: []}')"
out="$(grep_payload Grep "$MIXED" | run_ignore)"
hcheck "$(nonempty "$out")" "a Grep result spanning an ignored prefix is rewritten"
REPL="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.updatedToolOutput.content')"
hcheck "$(printf '%s' "$REPL" | grep -q 'real match' && echo 1 || echo 0)" "the non-ignored line survives"
hcheck "$(printf '%s' "$REPL" | grep -q 'vendored match' && echo 0 || echo 1)" "the ignored line is dropped"
hcheck "$(printf '%s' "$REPL" | grep -q 'suit token-ignore: hid 1' && echo 1 || echo 0)" "the count marker is appended"
hcheck "$(printf '%s' "$out" | jq -e '.hookSpecificOutput.updatedToolOutput
          | .numLines == (.content | split("\n") | length)' >/dev/null 2>&1 && echo 1 || echo 0)" \
  "the Grep replacement mirrors the shape (numLines recomputed)"

GLOBBED="$(jq -n --arg a "$REPO/vendor/lib/big.txt" --arg b "$REPO/src/ok.txt" \
  '{filenames: [$a, $b], numFiles: 2}')"
out="$(grep_payload Glob "$GLOBBED" | run_ignore)"
hcheck "$(nonempty "$out")" "a Glob result spanning an ignored prefix is rewritten"
hcheck "$(printf '%s' "$out" | jq -e '.hookSpecificOutput.updatedToolOutput
          | (.filenames | type == "array") and .numFiles == (.filenames | length)
            and (.filenames | any(contains("src/ok.txt")))
            and (.filenames | any(contains("vendor/lib/big.txt")) | not)' \
          >/dev/null 2>&1 && echo 1 || echo 0)" \
  "the Glob replacement keeps only non-ignored paths, shape mirrored"

hcheck "$(empty "$(grep_payload Grep "$MIXED" "{\"path\":\"$REPO/vendor\"}" | run_ignore)")" \
  "a search explicitly rooted inside the ignored prefix passes through"
CLEAN="$(jq -n --arg b "$REPO/src/ok.txt:1: real match" '{mode: "content", content: $b, numLines: 1}')"
hcheck "$(empty "$(grep_payload Grep "$CLEAN" | run_ignore)")" \
  "a result with nothing to drop passes through"
hcheck "$(empty "$(grep_payload Grep "$MIXED" | HOME="$HHOME" bash "$DISPATCH" --compress)")" \
  "no --ignore flag → the small mixed result passes through"
hcheck "$(empty "$(grep_payload Grep "$MIXED" | HOME="$HHOME" SUIT_TOKEN_FILTERS=off bash "$DISPATCH" --ignore)")" \
  "SUIT_TOKEN_FILTERS=off disables the result filtering"

echo
if [ "$hook_fail" -gt 0 ]; then
  echo "$hook_fail HOOK-SCRIPT FAILURE(S)"
  exit 1
fi
echo "all hook-script assertions passed"
