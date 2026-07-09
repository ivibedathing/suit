#!/usr/bin/env bash
# rtk compression benchmark: measure how many tokens rtk saves on real shell
# output, the deterministic (agent-noise-free) way to compare Suit's rtk cut
# against Headroom's — both install the same rtk, so this number is the rtk
# component of Headroom's ~50%. For each command it captures raw output, pipes
# the command through rtk (mirroring suit-rtk-rewrite.sh), counts TOKENS of
# each with Anthropic's tokenizer, and prints a per-command + total savings %.
#
# Token counting uses POST /v1/messages/count_tokens (needs ANTHROPIC_API_KEY;
# jq + curl). Without a key it falls back to a chars/4 ESTIMATE, clearly
# labelled — good enough for a rough read, not for a headline number.
#
# Usage:
#   scripts/rtk-bench.sh [cmdfile]
#     cmdfile: optional file of commands, one per line (# comments allowed).
#              Defaults to a small built-in read-only corpus. The big rtk wins
#              are on test/build output — pass your own `npm test`, `cargo
#              build`, etc. in a cmdfile to see them.
#   MODEL=claude-opus-4-8   token-count model (default; current tokenizer)
set -uo pipefail

# Resolve the cmdfile against the caller's cwd before we cd into the repo root.
CMDFILE="${1:-}"
if [ -n "$CMDFILE" ] && [ "${CMDFILE#/}" = "$CMDFILE" ]; then
  CMDFILE="$PWD/$CMDFILE"
fi

cd "$(dirname "$0")/.."
MODEL="${MODEL:-claude-opus-4-8}"

# Resolve rtk: Suit's installed copy, then PATH. Benchmarking needs it present.
RTK=""
if [ -x "$HOME/.suit/scripts/rtk" ]; then
  RTK="$HOME/.suit/scripts/rtk"
else
  RTK="$(command -v rtk 2>/dev/null || true)"
fi
if [ -z "$RTK" ]; then
  echo "error: rtk not found (looked in ~/.suit/scripts and PATH)." >&2
  echo "Install rtk (cargo install rtk, or put it on PATH), then re-run." >&2
  exit 1
fi

# Token counting backend.
MODE="estimate"
if [ -n "${ANTHROPIC_API_KEY:-}" ] && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
  MODE="api"
fi

# count_tokens <file> -> prints an integer token count for the file's contents.
count_tokens() {
  local file="$1"
  # Empty content has no tokens (and count_tokens rejects an empty message).
  if [ ! -s "$file" ]; then echo 0; return; fi
  if [ "$MODE" = "api" ]; then
    local body resp n
    body="$(jq -n --arg m "$MODEL" --rawfile t "$file" \
      '{model:$m, messages:[{role:"user", content:$t}]}')"
    resp="$(curl -s https://api.anthropic.com/v1/messages/count_tokens \
      -H "content-type: application/json" \
      -H "x-api-key: $ANTHROPIC_API_KEY" \
      -H "anthropic-version: 2023-06-01" \
      -d "$body")"
    n="$(printf '%s' "$resp" | jq -r '.input_tokens // empty' 2>/dev/null)"
    if [ -n "$n" ]; then echo "$n"; return; fi
    # API hiccup on this item -> fall back to the estimate rather than abort.
  fi
  # chars/4 estimate.
  echo $(( ($(wc -c < "$file") + 3) / 4 ))
}

# Built-in corpus (read-only, produces output anywhere). Override with a cmdfile.
default_corpus() {
  cat <<'CMDS'
git status
git log --oneline -100
git diff HEAD~20 HEAD --stat
ls -la
CMDS
}

scratch="$(mktemp -d -t rtk-bench)"
trap 'rm -rf "$scratch"' EXIT

echo "==> rtk compression benchmark   (rtk=$RTK, tokens=$MODE, model=$MODEL)"
if [ "$MODE" = "estimate" ]; then
  echo "    NOTE: no ANTHROPIC_API_KEY (or jq/curl) — token counts are chars/4 ESTIMATES."
fi
printf '%-40s %10s %10s %8s\n' "command" "raw" "rtk" "saved"
printf '%-40s %10s %10s %8s\n' "----------------------------------------" "--------" "--------" "------"

total_raw=0
total_rtk=0

run_one() {
  local cmd="$1"
  [ -z "$cmd" ] && return
  case "$cmd" in \#*) return ;; esac  # comment line

  # raw = the command's own output; rtk = command run through rtk (as the hook does).
  bash -c "$cmd" >"$scratch/raw" 2>&1
  bash -c "$RTK $cmd" >"$scratch/rtk" 2>&1

  local r t saved label
  r="$(count_tokens "$scratch/raw")"
  t="$(count_tokens "$scratch/rtk")"
  total_raw=$(( total_raw + r ))
  total_rtk=$(( total_rtk + t ))

  if [ "$r" -gt 0 ]; then
    saved=$(( (r - t) * 100 / r ))
    label="${saved}%"
  else
    label="-"
  fi
  # Trim the command for display.
  local disp="$cmd"
  [ "${#disp}" -gt 40 ] && disp="${disp:0:37}..."
  printf '%-40s %10s %10s %8s\n' "$disp" "$r" "$t" "$label"
}

if [ -n "$CMDFILE" ]; then
  [ -r "$CMDFILE" ] || { echo "error: cannot read cmdfile '$CMDFILE'" >&2; exit 1; }
  while IFS= read -r cmd || [ -n "$cmd" ]; do run_one "$cmd"; done < "$CMDFILE"
else
  while IFS= read -r cmd || [ -n "$cmd" ]; do run_one "$cmd"; done < <(default_corpus)
fi

printf '%-40s %10s %10s %8s\n' "----------------------------------------" "--------" "--------" "------"
if [ "$total_raw" -gt 0 ]; then
  overall=$(( (total_raw - total_rtk) * 100 / total_raw ))
  printf '%-40s %10s %10s %7s%%\n' "TOTAL" "$total_raw" "$total_rtk" "$overall"
  echo
  echo "rtk cut ~${overall}% of tool-output tokens on this corpus."
  echo "This is the rtk component Suit and Headroom share; Headroom's extra proxy"
  echo "layer (request-body compression) is not measured here."
else
  echo "No output produced by the corpus — supply a cmdfile with commands that print output."
fi
