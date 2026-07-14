#!/bin/bash
# Token-bench report test: exercises the pure aggregation half of
# scripts/token-bench.sh (--report) against a fixture results JSONL — median
# math, on/off deltas, ok-rate, total row, torn-line tolerance, and the CLI
# guard rails. The bench's live half (real claude sessions, real API spend) is
# deliberately not run here.
#
# Usage: scripts/token-bench-test.sh   (run from the repo root)
# Exit: 0 all pass, 1 an assertion failed.
set -euo pipefail

cd "$(dirname "$0")/.."
BENCH="$(pwd)/scripts/token-bench.sh"
SCRATCH="$(mktemp -d -t token-bench-test)"
trap 'rm -rf "$SCRATCH"' EXIT

fail=0
check() { # <condition-bool> <message>
  if [ "$1" = "1" ]; then echo "  ok: $2"; else echo "  FAIL: $2"; fail=$((fail + 1)); fi
}
has() { printf '%s' "$1" | grep -q "$2" && echo 1 || echo 0; }

FIX="$SCRATCH/results.jsonl"
cat >"$FIX" <<'EOF'
{"ts":1,"task":"big-read","arm":"off","rep":1,"is_error":false,"turns":6,"duration_ms":60000,"cost_usd":0.40,"input":2000,"cache_creation":48000,"cache_read":150000,"output":900,"ok":true}
{"ts":1,"task":"big-read","arm":"off","rep":2,"is_error":false,"turns":7,"duration_ms":65000,"cost_usd":0.44,"input":2200,"cache_creation":50000,"cache_read":160000,"output":950,"ok":true}
{"ts":1,"task":"big-read","arm":"off","rep":3,"is_error":false,"turns":6,"duration_ms":58000,"cost_usd":0.38,"input":1900,"cache_creation":46000,"cache_read":140000,"output":880,"ok":true}
{"ts":1,"task":"big-read","arm":"on","rep":1,"is_error":false,"turns":6,"duration_ms":52000,"cost_usd":0.21,"input":1800,"cache_creation":18000,"cache_read":120000,"output":920,"ok":true}
{"ts":1,"task":"big-read","arm":"on","rep":2,"is_error":false,"turns":6,"duration_ms":50000,"cost_usd":0.20,"input":1700,"cache_creation":17000,"cache_read":115000,"output":900,"ok":true}
{"ts":1,"task":"big-read","arm":"on","rep":3,"is_error":false,"turns":7,"duration_ms":55000,"cost_usd":0.23,"input":1900,"cache_creation":19500,"cache_read":125000,"output":940,"ok":false}
{"ts":1,"task":"git-history","arm":"off","rep":1,"is_error":false,"turns":4,"duration_ms":30000,"cost_usd":0.15,"input":900,"cache_creation":20000,"cache_read":80000,"output":600,"ok":null}
{"ts":1,"task":"git-history","arm":"on","rep":1,"is_error":false,"turns":4,"duration_ms":28000,"cost_usd":0.09,"input":800,"cache_creation":9000,"cache_read":70000,"output":610,"ok":null}
torn non-JSON line that a crashed run might leave behind
EOF

echo "==> Running bench-report assertions"
out="$(bash "$BENCH" --report "$FIX")"
# big-read off: fresh medians of 50000/52200/47900 -> 50000; cost median 0.40.
check "$(has "$out" 'big-read *off *3 *100% *50000 *150000 *900 *6 *0.4 *60')" \
  "the off arm reports per-task medians"
# big-read on: fresh median 19800 (median of 19800/18700/21400); 2 of 3 ok.
check "$(has "$out" 'big-read *on *3 *66% *19800 *120000 *920 *6 *0.21 *52 *-60% *-48%')" \
  "the on arm reports medians, ok-rate, and deltas vs off"
check "$(has "$out" 'git-history *off *1 *-')" "a task with no expect_regex shows '-' for ok"
check "$(has "$out" 'TOTAL(med-sums) *on .* -58% *-45%')" "the total row sums medians and deltas"
check "$(has "$out" 'fresh-in = median')" "the metric legend prints"

printf '%s\n' 'not json at all' >"$SCRATCH/garbage.jsonl"
out="$(bash "$BENCH" --report "$SCRATCH/garbage.jsonl")"
check "$(has "$out" 'No parseable result rows')" "an all-garbage file is reported, not fatal"

bash "$BENCH" --report "$SCRATCH/missing.jsonl" >/dev/null 2>&1 && rc=0 || rc=$?
check "$([ "$rc" != "0" ] && echo 1 || echo 0)" "a missing results file exits nonzero"

out="$(bash "$BENCH" --help)"
check "$(has "$out" 'A/B a fixed task suite')" "--help prints the header docs"

bash "$BENCH" --bogus >/dev/null 2>&1 && rc=0 || rc=$?
check "$([ "$rc" = "1" ] && echo 1 || echo 0)" "an unknown option exits 1"

# The default task suite must stay well-formed (ids, prompts, valid tool lists).
check "$(jq -e 'type == "array" and length > 0 and
                (map(.id and .prompt) | all) and
                (map(.allowed_tools // [] | type == "array") | all)' \
        scripts/token-bench/tasks.json >/dev/null 2>&1 && echo 1 || echo 0)" \
  "the default task suite parses and every task has id + prompt"

if [ "$fail" -gt 0 ]; then
  echo "$fail FAILURE(S)"
  exit 1
fi
echo "ALL PASS"
