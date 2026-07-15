#!/usr/bin/env bash
# Suit token-ignore firewall (Claude Code PreToolUse, Read tool).
#
# A repo opts in with `.claude/token-ignore` at its root: one root-relative
# path prefix per line (`#` comments, blank lines ignored) naming directories
# nobody should read wholesale — vendored dependencies, build output,
# generated code. A **full-file** Read of a path under an ignored prefix is
# denied with a reason that teaches the escape hatches; a range read
# (offset > 1 or any limit) is a deliberate, bounded read and always passes.
# The ignore file is found by walking up from the file being read toward /,
# so worktrees resolve to their own checked-out copy. Installed / removed by
# Suit's "Token-ignore heavy paths" toggle (see TokenIgnoreHook.swift); off
# by default. The Grep/Glob result side of the same feature lives in
# suit-posttool-filter.sh --ignore.
#
# Contract (mirrors suit-rtk-rewrite.sh): stdin carries a JSON object with
# .tool_name / .tool_input; to deny we print
#   {"hookSpecificOutput":{"hookEventName":"PreToolUse",
#     "permissionDecision":"deny","permissionDecisionReason":"..."}}
# and exit 0. To leave the Read untouched we print nothing and exit 0.
#
# FAIL OPEN: any missing dependency (jq), unparseable input, missing file, or
# absent ignore file ends in a clean no-op pass-through, so a broken firewall
# can never block a Read it wasn't meant to.
#
# Savings meter: every deny appends one JSONL counterfactual line to
# ~/.suit/token-savings.jsonl ({ts, session_id, tool: "Read", kind: "ignore",
# original_chars: <file bytes>, emitted_chars: <reason length>}), aggregated
# by scripts/token-savings-report.sh. SUIT_SAVINGS_LOG=0 disables the meter.
#
# Bench kill-switch: SUIT_TOKEN_FILTERS=off makes this hook a pure
# pass-through for the whole process (matches the other Suit token filters).

# Never let an error abort into a non-zero exit that would surface to Claude.
set +e
export LC_ALL=C

pass_through() { exit 0; }

# jq is required to read/emit the hook JSON; without it, pass through.
command -v jq >/dev/null 2>&1 || pass_through

INPUT="$(cat)"
[ -n "$INPUT" ] || pass_through

# Bench kill-switch (checked after the stdin read so the hook's writer never
# takes a SIGPIPE).
[ "${SUIT_TOKEN_FILTERS:-on}" = "off" ] && pass_through

TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)"
[ "$TOOL" = "Read" ] || pass_through

FILE="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
case "$FILE" in
  /*) ;;                                # only absolute paths are matchable
  *) pass_through ;;
esac
[ -f "$FILE" ] || pass_through

# The ignore list itself must always stay readable.
case "$FILE" in
  */.claude/token-ignore) pass_through ;;
esac

# A range read is deliberate and bounded — never firewalled (same rule as the
# read-dedup filter: offset > 1 or any limit means a partial read).
# TWIN: the identical jq test lives in suit-posttool-filter.sh (--dedup
# section); a rule change must land in both or the two filters disagree.
PARTIAL="$(printf '%s' "$INPUT" | jq -r \
  '.tool_input | if ((has("offset") and ((.offset // 0) > 1)) or has("limit")) then "1" else "0" end' \
  2>/dev/null)"
[ "$PARTIAL" = "0" ] || pass_through

# Walk up from the file toward / for the nearest .claude/token-ignore; its
# directory is the root the patterns are relative to. No file → no firewall.
# TWIN: suit-posttool-filter.sh (--ignore section) parses the same grammar for
# Grep/Glob results — keep the walk-up, the `%%#*` comment strip, and the
# absolute-vs-relative prefix rule byte-compatible across both scripts.
ROOT=""
DIR="$(dirname "$FILE")"
while [ -n "$DIR" ] && [ "$DIR" != "/" ]; do
  if [ -f "$DIR/.claude/token-ignore" ]; then
    ROOT="$DIR"
    break
  fi
  DIR="$(dirname "$DIR")"
done
[ -n "$ROOT" ] || pass_through

# First pattern whose absolute form prefixes the file wins.
MATCHED=""
while IFS= read -r LINE; do
  LINE="${LINE%%#*}"
  # shellcheck disable=SC2001
  LINE="$(printf '%s' "$LINE" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [ -n "$LINE" ] || continue
  case "$LINE" in
    /*) PREFIX="$LINE" ;;
    *)  PREFIX="$ROOT/$LINE" ;;
  esac
  case "$FILE" in
    "$PREFIX"*) MATCHED="$LINE"; break ;;
  esac
done <"$ROOT/.claude/token-ignore"
[ -n "$MATCHED" ] || pass_through

FSIZE="$(stat -f '%z' "$FILE" 2>/dev/null)"
REL="${FILE#"$ROOT"/}"
REASON="[suit token-ignore] $REL (${FSIZE:-?} bytes) matches '$MATCHED' in $ROOT/.claude/token-ignore — a vendored/heavy path whose full content is deliberately kept out of context. If you genuinely need part of it, Read a specific range with offset/limit, or Grep with an explicit path inside it; otherwise treat it as a dependency and move on."

OUT="$(jq -n --arg reason "$REASON" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}' \
  2>/dev/null)"
[ -n "$OUT" ] || pass_through

# Savings meter (best-effort; the counterfactual is the whole file).
# SCHEMA: one JSONL row shared with log_saving() in suit-posttool-filter.sh,
# read by TokenSavings.swift and scripts/token-savings-report.sh — change all
# four together.
if [ "${SUIT_SAVINGS_LOG:-1}" != "0" ]; then
  SID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
  mkdir -p "$HOME/.suit" 2>/dev/null
  printf '{"ts":%s,"session_id":"%s","tool":"Read","kind":"ignore","original_chars":%s,"emitted_chars":%s}\n' \
    "$(date +%s)" "${SID:-unknown}" "${FSIZE:-0}" "${#REASON}" \
    >>"$HOME/.suit/token-savings.jsonl" 2>/dev/null
fi

printf '%s' "$OUT"
exit 0
