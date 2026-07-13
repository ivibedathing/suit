#!/usr/bin/env bash
# Suit post-tool output filter (Claude Code PostToolUse, Read|Grep|Glob|Bash).
#
# Where the rtk PreToolUse hook compresses Bash output by rewriting the
# command, this hook works on the other side of a tool call: it rewrites the
# tool's *result* before it reaches the model's context window, via
#   {"hookSpecificOutput":{"hookEventName":"PostToolUse",
#     "updatedToolOutput":"<replacement>"}}
# (Claude Code ≥ 2.1.133) — reaching the built-in Read/Grep/Glob results rtk
# never sees. Installed / removed by Suit's Settings ▸ Claude toggles (see
# PostToolHook.swift); off by default. One script serves both toggles, its
# behaviors selected by flags, because matching hooks for an event run in
# parallel and two independent rewriters for the same result would race:
#   --compress      elide giant tool results (head + tail + a how-to-narrow
#                   marker); results under the size gate are never touched
#   --dedup         (reserved: stub re-reads of unchanged files)
#   --clear-cache   (reserved: PreCompact — empty the session's read cache)
#   --end-session   (reserved: SessionEnd — delete the session's read cache)
#
# FAIL OPEN: any missing dependency (jq), unparseable input, unrecognized
# tool_response shape, or an elision that wouldn't actually shrink the result
# ends in a clean no-op pass-through (print nothing, exit 0), so a broken
# filter can never break a tool result Claude was going to read.
#
# Debug: SUIT_POSTTOOL_DEBUG=1 appends each raw stdin payload to
# ~/.suit/posttool-debug.jsonl before filtering — the empirical way to inspect
# the per-tool tool_response shapes on the installed Claude Code.

# Never let an error abort into a non-zero exit that would surface to Claude.
set +e
# Byte-oriented text handling: the size gate and head/tail cuts count bytes,
# consistently, regardless of the user's locale.
export LC_ALL=C

pass_through() { exit 0; }

COMPRESS=0
for arg in "$@"; do
  case "$arg" in
    --compress) COMPRESS=1 ;;
    # --dedup / --clear-cache / --end-session land with the read-dedup
    # feature; until then they parse as no-ops so a newer settings.json
    # never breaks an older script.
    *) : ;;
  esac
done

# jq is required to read/emit the hook JSON; without it, pass through.
command -v jq >/dev/null 2>&1 || pass_through

INPUT="$(cat)"
[ -n "$INPUT" ] || pass_through

if [ "${SUIT_POSTTOOL_DEBUG:-0}" = "1" ]; then
  mkdir -p "$HOME/.suit" 2>/dev/null
  printf '%s\n' "$INPUT" >>"$HOME/.suit/posttool-debug.jsonl" 2>/dev/null
fi

[ "$COMPRESS" = "1" ] || pass_through

TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)"
case "$TOOL" in
  Read|Grep|Glob|Bash) ;;
  *) pass_through ;;
esac

# A Bash command already routed through rtk arrives pre-compressed — never
# second-guess it — and the rtk bypass markers opt a command out of Suit's
# filtering entirely, this hook included.
if [ "$TOOL" = "Bash" ]; then
  CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)"
  case "$CMD" in
    rtk\ *|*/rtk\ *) pass_through ;;
    NO_RTK=1|NO_RTK=1\ *) pass_through ;;
    *"# nortk"*) pass_through ;;
  esac
fi

# Extract the result text defensively: the hook docs don't pin tool_response's
# shape per tool, so accept a plain string or the known object fields — and
# pass anything else through untouched. A Bash object result keeps its stderr
# (labeled) so a failure's diagnostics survive the elision.
TEXT="$(printf '%s' "$INPUT" | jq -r '
  .tool_response
  | if type == "string" then .
    elif type == "object" then
      (if has("stdout") then
         ((.stdout // "")
          + (if ((.stderr // "") | length) > 0 then "\n[stderr]\n" + .stderr else "" end))
       else
         (.output? // .content? // .file?.content?
          // (try (.filenames | join("\n")) catch null) // empty)
       end)
    else empty end
  | if type == "string" then . else empty end
' 2>/dev/null)"
[ -n "$TEXT" ] || pass_through

# Size gate: results under ~30k chars (≈7.5k tokens) are never touched.
GATE=30000
SIZE=${#TEXT}
[ "$SIZE" -gt "$GATE" ] || pass_through

NLINES="$(printf '%s\n' "$TEXT" | wc -l | tr -d ' ')"
if [ "$NLINES" -gt 300 ]; then
  # Line-shaped output: keep the first 200 and last 50 lines.
  HEAD="$(printf '%s\n' "$TEXT" | head -n 200)"
  TAIL="$(printf '%s\n' "$TEXT" | tail -n 50)"
  CUT="$((NLINES - 250)) of $NLINES lines"
else
  # Few enormous lines (minified / single-blob output): cut by bytes instead.
  HEAD="$(printf '%s' "$TEXT" | head -c 20000)"
  TAIL="$(printf '%s' "$TEXT" | tail -c 4000)"
  CUT="the middle"
fi

MARKER="[suit: elided $CUT ($SIZE chars) of $TOOL output. Re-run with a narrower query if the elided middle is needed — Grep: head_limit / -A / -B, Read: offset / limit, Glob: a tighter pattern, Bash: filter or paginate the command.]"
ELIDED="$HEAD
$MARKER
$TAIL"

# Only replace when the elision genuinely shrinks the result.
[ "${#ELIDED}" -lt "$SIZE" ] || pass_through

printf '%s' "$ELIDED" | jq -Rs \
  '{hookSpecificOutput: {hookEventName: "PostToolUse", updatedToolOutput: .}}' \
  2>/dev/null || pass_through

exit 0
