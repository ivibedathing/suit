#!/bin/bash
# Token-savings reporter test: exercises scripts/token-savings-report.sh (the
# aggregator over the JSONL meter that suit-posttool-filter.sh appends) against
# fixture logs — totals, kind/tool grouping, the --session filter, torn-line
# tolerance, and the empty-log message. Pure shell + jq; no app deps.
#
# Usage: scripts/savings-report-test.sh   (run from the repo root)
# Exit: 0 all pass, 1 an assertion failed.
set -euo pipefail

cd "$(dirname "$0")/.."
REPORT="$(pwd)/scripts/token-savings-report.sh"
SCRATCH="$(mktemp -d -t savings-report-test)"
trap 'rm -rf "$SCRATCH"' EXIT

fail=0
check() { # <condition-bool> <message>
  if [ "$1" = "1" ]; then echo "  ok: $2"; else echo "  FAIL: $2"; fail=$((fail + 1)); fi
}
has() { printf '%s' "$1" | grep -q "$2" && echo 1 || echo 0; }

FIX="$SCRATCH/savings.jsonl"
cat >"$FIX" <<'EOF'
{"ts":1783990000,"session_id":"s1","tool":"Grep","kind":"compress","original_chars":80000,"emitted_chars":10000}
{"ts":1783990100,"session_id":"s1","tool":"Read","kind":"dedup","original_chars":48000,"emitted_chars":200}
{"ts":1783903600,"session_id":"s2","tool":"Bash","kind":"compress","original_chars":40000,"emitted_chars":8000}
this line is torn garbage, not JSON
EOF

echo "==> Running reporter assertions"
out="$(bash "$REPORT" "$FIX")"
check "$(has "$out" '3 rewrites across 2 session(s)')" "header counts rewrites and sessions"
check "$(has "$out" 'TOTAL *3 *168000 *18200 *149800 *37450 *89%')" \
  "the TOTAL row sums originals, emissions, savings, est tokens, and percent"
check "$(has "$out" 'compress *2 *120000 *18000 *102000')" "compress rows group by kind"
check "$(has "$out" 'dedup *1 *48000 *200 *47800 *11950 *99%')" "dedup row is exact"
check "$(has "$out" 'Grep *1 *80000')" "tool grouping includes Grep"
check "$(has "$out" 'by day (UTC):')" "day section renders"

out="$(bash "$REPORT" --session s1 "$FIX")"
check "$(has "$out" '2 rewrites across 1 session(s)')" "--session filters to one session"
check "$(has "$out" 'TOTAL *2 *128000 *10200')" "--session totals only that session's rows"

out="$(bash "$REPORT" --session nope "$FIX")"
check "$(has "$out" 'No matching savings rows')" "an all-filtered log says so"

out="$(bash "$REPORT" - <"$FIX")"
check "$(has "$out" '3 rewrites')" "'-' reads the log from stdin"

: >"$SCRATCH/empty.jsonl"
out="$(bash "$REPORT" "$SCRATCH/empty.jsonl")"
check "$(has "$out" 'No savings recorded yet')" "an empty log reports, exit 0"

out="$(bash "$REPORT" "$SCRATCH/missing.jsonl")"
check "$(has "$out" 'No savings recorded yet')" "a missing log reports, exit 0"

bash "$REPORT" --bogus >/dev/null 2>&1 && rc=0 || rc=$?
check "$([ "$rc" = "1" ] && echo 1 || echo 0)" "an unknown option exits 1"

if [ "$fail" -gt 0 ]; then
  echo "$fail FAILURE(S)"
  exit 1
fi
echo "ALL PASS"
