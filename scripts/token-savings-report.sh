#!/usr/bin/env bash
# Suit token-savings report: aggregate the savings meter that
# scripts/claude/suit-posttool-filter.sh appends to ~/.suit/token-savings.jsonl —
# one JSONL line per rewrite recording the counterfactual the hook saw
# ({ts, session_id, tool, kind: compress|dedup|ignore, original_chars, emitted_chars}).
# This is the exact, zero-variance measure of what Suit's filters cut on real
# sessions: the original result was in the hook's hands, so nothing is
# simulated. What it can't see is second-order behavior (extra turns after a
# stub) — that's scripts/token-bench.sh's job.
#
# Token numbers are chars/4 ESTIMATES (the meter keeps counts, not text, so
# exact tokenization isn't possible after the fact).
#
# Usage:
#   scripts/token-savings-report.sh [--session SID] [--today] [file]
#     file: savings JSONL (default ~/.suit/token-savings.jsonl, "-" for stdin)
#     --session SID: only rows from one Claude session
#     --today: only rows from the last 24 h
# Exit: 0 (a missing/empty log is reported, not an error), 1 on usage errors.
set -uo pipefail

SESSION=""
SINCE=0
FILE="$HOME/.suit/token-savings.jsonl"
while [ $# -gt 0 ]; do
  case "$1" in
    --session)
      [ $# -ge 2 ] || { echo "error: --session needs an argument" >&2; exit 1; }
      SESSION="$2"; shift 2 ;;
    --today) SINCE="$(( $(date +%s) - 86400 ))"; shift ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -) FILE="-"; shift ;;
    -*) echo "error: unknown option '$1' (try -h)" >&2; exit 1 ;;
    *) FILE="$1"; shift ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }

if [ "$FILE" = "-" ]; then
  DATA="$(cat)"
else
  if [ ! -s "$FILE" ]; then
    echo "No savings recorded yet ($FILE is missing or empty)."
    echo "The meter fills as the Suit post-tool filter rewrites results (Settings ▸ Claude toggles)."
    exit 0
  fi
  DATA="$(cat "$FILE")"
fi

# One jq pass: filter, then emit formatted sections. Rows that aren't objects
# (torn writes, hand edits) are dropped rather than aborting the report.
printf '%s\n' "$DATA" | jq -rRs --arg sess "$SESSION" --argjson since "$SINCE" '
  def est_tokens: ((. + 2) / 4 | floor);
  def agg:
    {n: length,
     orig: (map(.original_chars // 0) | add // 0),
     emit: (map(.emitted_chars // 0) | add // 0)}
    | .saved = (.orig - .emit);
  def row($label): agg
    | [$label, .n, .orig, .emit, .saved, (.saved | est_tokens),
       (if .orig > 0 then "\((.saved * 100 / .orig) | floor)%" else "0%" end)]
    | @tsv;

  [splits("\n") | select(length > 0) | (try fromjson catch empty)]
  | map(select(type == "object"))
  | map(select($sess == "" or .session_id == $sess))
  | map(select((.ts // 0) >= $since))
  | if length == 0 then
      "No matching savings rows."
    else
      . as $rows
      | ($rows | map(.session_id) | unique | length) as $sessions
      | (
          ["# Suit token savings — \($rows | length) rewrites across \($sessions) session(s)",
           "  (tokens ≈ chars/4 estimate; saved% = share of the original cut)",
           "",
           (["", "rewrites", "orig chars", "emit chars", "saved chars", "≈tokens", "saved%"] | @tsv),
           (["by kind:", "", "", "", "", "", ""] | @tsv)]
          + [ $rows | group_by(.kind)[] | row("  \(.[0].kind // "?")") ]
          + [ (["by tool:", "", "", "", "", "", ""] | @tsv) ]
          + [ $rows | group_by(.tool)[] | row("  \(.[0].tool // "?")") ]
          + [ (["by day (UTC):", "", "", "", "", "", ""] | @tsv) ]
          + [ $rows | group_by((.ts // 0) | gmtime | strftime("%Y-%m-%d"))[]
              | row("  \((.[0].ts // 0) | gmtime | strftime("%Y-%m-%d"))") ]
          + [ ($rows | row("TOTAL")) ]
        ) | .[]
    end
' | awk -F'\t' '
  NF <= 1 { print; next }
  { printf "%-14s %9s %12s %12s %12s %10s %7s\n", $1, $2, $3, $4, $5, $6, $7 }
'
