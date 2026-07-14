#!/usr/bin/env bash
# Suit end-to-end token benchmark: A/B a fixed task suite through headless
# Claude Code with Suit's token filters ON vs OFF and compare real session
# metrics — fresh input tokens (input + cache-creation, the context-growth
# number the filters target), cache reads, output tokens, turns, cost, wall
# time, and a per-task success check. This is the layer that catches what the
# always-on savings meter (scripts/token-savings-report.sh) can't: second-order
# effects like a dedup stub causing an extra re-read turn.
#
# The OFF arm runs with SUIT_TOKEN_FILTERS=off, which both hook scripts honor
# as a per-process pass-through — ~/.claude/settings.json is never touched.
# The ON arm uses your globally installed hooks if present (benchmarks Suit as
# configured); otherwise a bench-only --settings file wires the repo's filter
# script with --compress --dedup (plus the rtk rewrite when rtk is available).
# Arms are interleaved (on, off, on, off…) so prompt-cache weather averages
# out evenly instead of favoring whichever arm runs second.
#
# Each run gets a fresh local clone of this repo as its fixture, so both arms
# start from identical state. This is REAL API SPEND (reps × tasks × 2 claude
# sessions) and takes minutes — it is deliberately not in scripts/test.sh.
#
# Usage:
#   scripts/token-bench.sh [--reps N] [--tasks FILE] [--model M]
#                          [--max-turns N] [--out FILE]
#     --reps N       repetitions per (task, arm); medians reported (default 3)
#     --tasks FILE   task suite JSON (default scripts/token-bench/tasks.json);
#                    entries: {id, prompt, expect_regex?, allowed_tools?}
#     --model M      forwarded to claude --model
#     --max-turns N  per-session turn cap (default 25)
#     --out FILE     results JSONL (default ~/.suit/token-bench/results-<ts>.jsonl)
#   scripts/token-bench.sh --report FILE
#     aggregate an existing results JSONL (pure; no API calls) — also runs
#     automatically at the end of a bench.
# Exit: 0 on success (individual failed runs are recorded, not fatal).
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

REPS=3
TASKS="$ROOT/scripts/token-bench/tasks.json"
MODEL=""
MAXTURNS=25
OUTFILE=""
REPORT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --reps) REPS="${2:?--reps needs a number}"; shift 2 ;;
    --tasks) TASKS="${2:?--tasks needs a file}"; shift 2 ;;
    --model) MODEL="${2:?--model needs a name}"; shift 2 ;;
    --max-turns) MAXTURNS="${2:?--max-turns needs a number}"; shift 2 ;;
    --out) OUTFILE="${2:?--out needs a file}"; shift 2 ;;
    --report) REPORT="${2:?--report needs a results file}"; shift 2 ;;
    -h|--help) sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unknown option '$1' (try -h)" >&2; exit 1 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }

# --- Report mode (pure aggregation; also the bench's final step) --------------
report() {
  local file="$1"
  [ -s "$file" ] || { echo "error: no results in '$file'" >&2; return 1; }
  jq -rRs '
    def median: sort
      | if length == 0 then 0
        elif length % 2 == 1 then .[length / 2 | floor]
        else ((.[length / 2 - 1] + .[length / 2]) / 2) end;
    def m(f): map(f) | median | round;
    def arm_row: {
      n: length,
      ok: (map(select(.ok == true)) | length),
      checked: (map(select(.ok != null)) | length),
      fresh: m(.input + .cache_creation),
      cache_read: m(.cache_read),
      out: m(.output),
      turns: m(.turns),
      cost: (map(.cost_usd) | median * 1000 | round / 1000),
      secs: (m(.duration_ms) / 1000 | round)
    };
    def okpct: if .checked == 0 then "-" else "\(.ok * 100 / .checked | floor)%" end;
    def delta($on; $off; f): ($off | f) as $o
      | if $o == 0 then "-" else "\((($on | f) - $o) * 100 / $o | round)%" end;

    [splits("\n") | select(length > 0) | (try fromjson catch empty)]
    | map(select(type == "object" and .task != null))
    | if length == 0 then "No parseable result rows." else
        group_by(.task)
        | map({task: .[0].task,
               on: (map(select(.arm == "on")) | arm_row),
               off: (map(select(.arm == "off")) | arm_row)})
        | (
            [ (["task", "arm", "n", "ok", "fresh-in", "cache-rd", "out", "turns", "cost$", "secs", "Δfresh", "Δcost"] | @tsv) ]
            + [ .[]
                | ( [.task, "off", .off.n, (.off | okpct), .off.fresh, .off.cache_read,
                     .off.out, .off.turns, .off.cost, .off.secs, "", ""] | @tsv ),
                  ( [.task, "on", .on.n, (.on | okpct), .on.fresh, .on.cache_read,
                     .on.out, .on.turns, .on.cost, .on.secs,
                     delta(.on; .off; .fresh), delta(.on; .off; .cost)] | @tsv )
              ]
            + ( . as $t
                | [ ( ["TOTAL(med-sums)", "off", "", "",
                       ($t | map(.off.fresh) | add), ($t | map(.off.cache_read) | add),
                       ($t | map(.off.out) | add), ($t | map(.off.turns) | add),
                       ($t | map(.off.cost) | add * 1000 | round / 1000),
                       ($t | map(.off.secs) | add), "", ""] | @tsv ),
                    ( ["TOTAL(med-sums)", "on", "", "",
                       ($t | map(.on.fresh) | add), ($t | map(.on.cache_read) | add),
                       ($t | map(.on.out) | add), ($t | map(.on.turns) | add),
                       ($t | map(.on.cost) | add * 1000 | round / 1000),
                       ($t | map(.on.secs) | add),
                       delta(($t | map(.on.fresh) | add); ($t | map(.off.fresh) | add); .),
                       delta(($t | map(.on.cost) | add); ($t | map(.off.cost) | add); .)] | @tsv ) ]
              )
          ) | .[]
      end
  ' "$file" | awk -F'\t' '
    NF <= 1 { print; next }
    { printf "%-16s %-4s %3s %5s %10s %10s %7s %6s %7s %5s %8s %8s\n",
        $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12 }
  '
  echo
  echo "fresh-in = median(input + cache-creation) per session: the context-growth tokens"
  echo "the filters target. Δ columns compare the on arm to the off arm (negative = saved)."
  echo "ok = success-check pass rate — a token cut that lowers it is a regression, not a win."
}

if [ -n "$REPORT" ]; then
  report "$REPORT"
  exit $?
fi

# --- Bench mode ----------------------------------------------------------------
command -v claude >/dev/null 2>&1 || { echo "error: the claude CLI is required" >&2; exit 1; }
[ -r "$TASKS" ] || { echo "error: cannot read task suite '$TASKS'" >&2; exit 1; }
jq -e 'type == "array" and length > 0' "$TASKS" >/dev/null 2>&1 \
  || { echo "error: '$TASKS' is not a non-empty JSON array of tasks" >&2; exit 1; }

if [ -z "$OUTFILE" ]; then
  mkdir -p "$HOME/.suit/token-bench"
  OUTFILE="$HOME/.suit/token-bench/results-$(date +%Y%m%d-%H%M%S).jsonl"
fi

SCRATCH="$(mktemp -d -t token-bench)"
trap 'rm -rf "$SCRATCH"' EXIT

# The ON arm: prefer the user's globally installed hooks (benchmarks Suit as
# configured). The installed script copies must honor the kill-switch, or the
# OFF arm silently isn't off — sync them from the repo when they've drifted.
SETTINGS="$HOME/.claude/settings.json"
INSTALLED=0
if [ -f "$SETTINGS" ] && jq -e '
     [.. | .command? // empty | strings | select(test("suit-posttool-filter"))] | length > 0
   ' "$SETTINGS" >/dev/null 2>&1; then
  INSTALLED=1
fi
for script in suit-posttool-filter.sh suit-rtk-rewrite.sh; do
  inst="$HOME/.suit/scripts/$script"
  if [ -f "$inst" ] && ! cmp -s "$inst" "$ROOT/scripts/claude/$script"; then
    cp "$ROOT/scripts/claude/$script" "$inst" && chmod +x "$inst"
    echo "note: synced installed $script to this repo's version (kill-switch + meter)."
  fi
done

ON_ARGS=()
if [ "$INSTALLED" = "1" ]; then
  flags="$(jq -r '[.. | .command? // empty | strings | select(test("suit-posttool-filter"))][0]' \
    "$SETTINGS" 2>/dev/null | sed 's/^.*suit-posttool-filter\.sh//')"
  echo "==> ON arm: globally installed hooks (posttool flags:${flags:- none})"
else
  BENCH_ON="$SCRATCH/bench-on-settings.json"
  FILTER="$ROOT/scripts/claude/suit-posttool-filter.sh"
  RTK_HOOK=""
  if command -v rtk >/dev/null 2>&1 || [ -x "$HOME/.suit/scripts/rtk" ]; then
    RTK_HOOK="$ROOT/scripts/claude/suit-rtk-rewrite.sh"
  fi
  jq -n --arg f "$FILTER" --arg rtk "$RTK_HOOK" '
    {hooks: ({
       PostToolUse: [{matcher: "Read|Grep|Glob|Bash",
                      hooks: [{type: "command", command: "\($f) --compress --dedup"}]}],
       PreCompact: [{hooks: [{type: "command", command: "\($f) --clear-cache"}]}],
       SessionEnd: [{hooks: [{type: "command", command: "\($f) --end-session"}]}]
     } + (if $rtk != "" then
       {PreToolUse: [{matcher: "Bash", hooks: [{type: "command", command: $rtk}]}]}
     else {} end))}' >"$BENCH_ON"
  ON_ARGS=(--settings "$BENCH_ON")
  echo "==> ON arm: bench-only --settings (repo filter script, --compress --dedup${RTK_HOOK:+, rtk rewrite})"
fi

NTASKS="$(jq 'length' "$TASKS")"
echo "==> $NTASKS tasks × 2 arms × $REPS reps → $((NTASKS * 2 * REPS)) claude sessions (results: $OUTFILE)"
[ -n "$MODEL" ] && echo "==> model: $MODEL"

run_one() { # <task-json> <arm> <rep>
  local task="$1" arm="$2" rep="$3"
  local id prompt expect tools
  id="$(jq -r '.id' <<<"$task")"
  prompt="$(jq -r '.prompt' <<<"$task")"
  expect="$(jq -r '.expect_regex // ""' <<<"$task")"
  tools="$(jq -r '(.allowed_tools // []) | join(",")' <<<"$task")"

  local fix="$SCRATCH/fix-$id-$arm-$rep"
  if ! git clone -q --local --no-hardlinks "$ROOT" "$fix" 2>/dev/null; then
    echo "  [$rep] $id/$arm: fixture clone FAILED, skipping" >&2
    return 0
  fi

  # SUIT_TOKEN_FILTERS is set explicitly for both arms ("on" is the scripts'
  # default) — macOS bash 3.2 treats an empty array expansion as unbound.
  local -a envv=(SUIT_TOKEN_FILTERS="$([ "$arm" = "off" ] && echo off || echo on)")
  local -a args=(-p "$prompt" --output-format json --max-turns "$MAXTURNS")
  [ "$arm" = "on" ] && [ "${#ON_ARGS[@]}" -gt 0 ] && args+=("${ON_ARGS[@]}")
  [ -n "$tools" ] && args+=(--allowedTools "$tools")
  [ -n "$MODEL" ] && args+=(--model "$MODEL")

  local out rec
  out="$(cd "$fix" && env "${envv[@]}" claude "${args[@]}" 2>"$fix/.claude-stderr")"
  rec="$(jq -c --arg task "$id" --arg arm "$arm" --argjson rep "$rep" --arg exp "$expect" '
      {ts: (now | floor), task: $task, arm: $arm, rep: $rep,
       is_error: (.is_error // false),
       turns: (.num_turns // 0),
       duration_ms: (.duration_ms // 0),
       cost_usd: (.total_cost_usd // 0),
       input: (.usage.input_tokens // 0),
       cache_creation: (.usage.cache_creation_input_tokens // 0),
       cache_read: (.usage.cache_read_input_tokens // 0),
       output: (.usage.output_tokens // 0),
       ok: (if $exp == "" then null
            else ((.result // "") | test($exp)) end)}
    ' <<<"$out" 2>/dev/null)"
  if [ -z "$rec" ]; then
    echo "  [$rep] $id/$arm: claude produced no parseable result ($(head -c 200 "$fix/.claude-stderr" 2>/dev/null | tr '\n' ' '))" >&2
    rec="$(jq -nc --arg task "$id" --arg arm "$arm" --argjson rep "$rep" \
      '{ts: (now | floor), task: $task, arm: $arm, rep: $rep, is_error: true,
        turns: 0, duration_ms: 0, cost_usd: 0, input: 0, cache_creation: 0,
        cache_read: 0, output: 0, ok: false}')"
  fi
  printf '%s\n' "$rec" >>"$OUTFILE"
  jq -r '"  [\(.rep)] \(.task)/\(.arm): fresh=\(.input + .cache_creation) cache-rd=\(.cache_read) out=\(.output) turns=\(.turns) cost=$\(.cost_usd) ok=\(.ok)"' <<<"$rec"
  rm -rf "$fix"
}

for rep in $(seq 1 "$REPS"); do
  for i in $(seq 0 $((NTASKS - 1))); do
    task="$(jq -c ".[$i]" "$TASKS")"
    for arm in on off; do
      run_one "$task" "$arm" "$rep"
    done
  done
done

echo
report "$OUTFILE"
