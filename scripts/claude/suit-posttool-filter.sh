#!/usr/bin/env bash
# Suit post-tool output filter (Claude Code PostToolUse, Read|Grep|Glob|Bash;
# plus PreCompact / SessionEnd for the read-cache lifecycle).
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
#   --dedup         read-once: replace a repeat full-file Read of an unchanged
#                   file with a short "already in this conversation" stub,
#                   tracked per session in ~/.suit/read-cache/<sid>.json
#   --clear-cache   PreCompact: empty the session's read cache — after any
#                   compaction the previously-read content is gone from
#                   context, so "already in this conversation" would be a lie
#   --end-session   SessionEnd: delete the session's read-cache file
#
# Dedup correctness rules: only full-file Reads participate (offset/limit
# reads always pass through, untracked); entries key on the file's current
# mtime+size so any edit forces a real re-read; a stub is served at most once
# in a row — a second consecutive re-read passes the full content through
# (re-reading twice is a strong signal the content genuinely fell out of
# context) and re-arms the entry.
#
# FAIL OPEN: any missing dependency (jq), unparseable input, unrecognized
# tool_response shape, unreadable file/cache, or an elision that wouldn't
# actually shrink the result ends in a clean no-op pass-through (print
# nothing, exit 0), so a broken filter can never break a tool result Claude
# was going to read.
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
DEDUP=0
MODE=""
for arg in "$@"; do
  case "$arg" in
    --compress) COMPRESS=1 ;;
    --dedup) DEDUP=1 ;;
    --clear-cache) MODE="clear" ;;
    --end-session) MODE="end" ;;
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

SID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
CACHE_DIR="$HOME/.suit/read-cache"
CACHE="$CACHE_DIR/$SID.json"

# Atomically replace the session's cache file with the JSON on stdin.
write_cache() {
  mkdir -p "$CACHE_DIR" 2>/dev/null || return 1
  local tmp rc
  tmp="$(mktemp "$CACHE_DIR/.tmp.XXXXXX" 2>/dev/null)" || return 1
  cat >"$tmp" 2>/dev/null && mv -f "$tmp" "$CACHE" 2>/dev/null
  rc=$?
  rm -f "$tmp" 2>/dev/null
  return $rc
}

# --- Cache lifecycle modes (PreCompact / SessionEnd invocations) --------------
if [ "$MODE" = "clear" ]; then
  if [ -n "$SID" ] && [ -f "$CACHE" ]; then
    printf '{"session_id":"%s","files":{}}' "$SID" | write_cache
  fi
  exit 0
fi
if [ "$MODE" = "end" ]; then
  [ -n "$SID" ] && rm -f "$CACHE" 2>/dev/null
  exit 0
fi

TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)"
case "$TOOL" in
  Read|Grep|Glob|Bash) ;;
  *) pass_through ;;
esac

# --- Read-dedup (before compression, so a stub is never elided) ---------------
if [ "$DEDUP" = "1" ] && [ "$TOOL" = "Read" ] && [ -n "$SID" ]; then
  FILE="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
  # Only full-file reads participate: an offset past the top or any limit is a
  # deliberate range read — pass it through and never track it.
  PARTIAL="$(printf '%s' "$INPUT" | jq -r \
    '.tool_input | if ((has("offset") and ((.offset // 0) > 1)) or has("limit")) then "1" else "0" end' \
    2>/dev/null)"
  if [ -n "$FILE" ] && [ "$PARTIAL" = "0" ] && [ -f "$FILE" ]; then
    STAT="$(stat -f '%m %z' "$FILE" 2>/dev/null)"
    MTIME="${STAT%% *}"
    FSIZE="${STAT##* }"
    NOW="$(date +%s)"
    if [ -n "$MTIME" ] && [ -n "$FSIZE" ]; then
      ENTRY="$(jq -c --arg f "$FILE" '.files[$f] // empty' "$CACHE" 2>/dev/null)"
      E_MTIME="$(printf '%s' "$ENTRY" | jq -r '.mtime // empty' 2>/dev/null)"
      E_SIZE="$(printf '%s' "$ENTRY" | jq -r '.size // empty' 2>/dev/null)"
      E_STUBBED="$(printf '%s' "$ENTRY" | jq -r '.stubbed // false' 2>/dev/null)"
      E_READAT="$(printf '%s' "$ENTRY" | jq -r '.read_at // 0' 2>/dev/null)"
      FRESH=0
      [ -n "$E_READAT" ] && [ "$E_READAT" -gt 0 ] 2>/dev/null \
        && [ "$((NOW - E_READAT))" -lt 7200 ] && FRESH=1

      if [ "$E_MTIME" = "$MTIME" ] && [ "$E_SIZE" = "$FSIZE" ] \
         && [ "$FRESH" = "1" ] && [ "$E_STUBBED" = "false" ]; then
        # Unchanged since the last full read → serve the stub, once.
        E_LINES="$(printf '%s' "$ENTRY" | jq -r '.lines // 0' 2>/dev/null)"
        WHEN="$(date -r "$E_READAT" '+%H:%M:%S' 2>/dev/null)"
        jq --arg f "$FILE" \
           '.files[$f].stubbed = true' "$CACHE" 2>/dev/null | write_cache
        STUB="[suit read-dedup: $FILE is unchanged since your full read at ${WHEN:-earlier} ($E_LINES lines, $FSIZE bytes) — its content is already in this conversation. Read it again to force the full file, or use offset/limit for a specific range.]"
        printf '%s' "$STUB" | jq -Rs \
          '{hookSpecificOutput: {hookEventName: "PostToolUse", updatedToolOutput: .}}' \
          2>/dev/null || pass_through
        exit 0
      fi

      # Miss, changed file, stale entry, or the stub-once loop breaker (a
      # second consecutive re-read): record/re-arm and pass the content on.
      LINES="$(wc -l <"$FILE" 2>/dev/null | tr -d ' ')"
      BASE='{"session_id":"","files":{}}'
      [ -f "$CACHE" ] && BASE="$(cat "$CACHE" 2>/dev/null)"
      printf '%s' "$BASE" | jq \
        --arg sid "$SID" --arg f "$FILE" \
        --argjson m "${MTIME:-0}" --argjson z "${FSIZE:-0}" \
        --argjson l "${LINES:-0}" --argjson t "$NOW" '
          .session_id = $sid
          | .updated_at = $t
          | .files[$f] = {mtime: $m, size: $z, lines: $l, read_at: $t, stubbed: false}
          | .files |= (if (keys | length) > 500
                       then (to_entries | sort_by(.value.read_at) | .[-500:] | from_entries)
                       else . end)
        ' 2>/dev/null | write_cache
      # Opportunistic GC: crashed sessions never fire SessionEnd; sweep cache
      # files untouched for 2+ days.
      find "$CACHE_DIR" -name '*.json' -type f -mtime +2 -delete 2>/dev/null
    fi
  fi
fi

# --- Compression ---------------------------------------------------------------
[ "$COMPRESS" = "1" ] || pass_through

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
