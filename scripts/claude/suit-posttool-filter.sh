#!/usr/bin/env bash
# Suit post-tool output filter (Claude Code PostToolUse, Read|Grep|Glob|Bash;
# plus PreCompact / SessionEnd for the read-cache lifecycle).
#
# Where the rtk PreToolUse hook compresses Bash output by rewriting the
# command, this hook works on the other side of a tool call: it rewrites the
# tool's *result* before it reaches the model's context window, via
#   {"hookSpecificOutput":{"hookEventName":"PostToolUse",
#     "updatedToolOutput":<same shape as tool_response, content replaced>}}
# — reaching the built-in Read/Grep/Glob results rtk never sees. The
# replacement MUST mirror the tool's own tool_response shape (see REPLACE_JQ);
# Claude Code silently ignores a mismatched shape (e.g. a bare string for
# Read's object result — verified empirically on 2.1.208). Installed / removed by Suit's Settings ▸ Claude toggles (see
# PostToolHook.swift); off by default. One script serves both toggles, its
# behaviors selected by flags, because matching hooks for an event run in
# parallel and two independent rewriters for the same result would race:
#   --compress      elide giant tool results (head + tail + a how-to-narrow
#                   marker); results under the size gate are never touched
#   --dedup         read-once: replace a repeat full-file Read of an unchanged
#                   file with a short "already in this conversation" stub,
#                   tracked per session in ~/.suit/read-cache/<sid>.json
#   --ignore        token-ignore: drop Grep/Glob result lines under the
#                   prefixes listed in the repo's .claude/token-ignore
#                   (found walking up from tool_input.path, else .cwd),
#                   replaced by a one-line count marker. A search whose
#                   tool_input.path is explicitly inside an ignored prefix
#                   passes through untouched. The Read side of the feature
#                   is the suit-token-ignore.sh PreToolUse hook.
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
# Savings meter: every rewrite appends one JSONL line to
# ~/.suit/token-savings.jsonl recording the counterfactual this hook just saw —
# the chars the original result would have cost vs the chars actually emitted
# ({ts, session_id, tool, kind: compress|dedup, original_chars, emitted_chars}).
# scripts/token-savings-report.sh aggregates it. Best-effort: a failed append
# never affects the rewrite. SUIT_SAVINGS_LOG=0 disables the meter.
#
# Bench kill-switch: SUIT_TOKEN_FILTERS=off makes this hook a pure pass-through
# for the whole process, so an A/B benchmark (scripts/token-bench.sh) can run
# a filters-off arm without touching ~/.claude/settings.json.
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
IGNORE=0
MODE=""
for arg in "$@"; do
  case "$arg" in
    --compress) COMPRESS=1 ;;
    --dedup) DEDUP=1 ;;
    --ignore) IGNORE=1 ;;
    --clear-cache) MODE="clear" ;;
    --end-session) MODE="end" ;;
    *) : ;;
  esac
done

# jq is required to read/emit the hook JSON; without it, pass through.
command -v jq >/dev/null 2>&1 || pass_through

# Savings meter: log_saving <kind> <original_chars> <emitted_chars> appends one
# JSONL counterfactual line. Best-effort — never lets a failure escape.
# SCHEMA: the same row is written inline by suit-token-ignore.sh and read by
# TokenSavings.swift + scripts/token-savings-report.sh — change all four
# together.
log_saving() {
  [ "${SUIT_SAVINGS_LOG:-1}" = "0" ] && return 0
  mkdir -p "$HOME/.suit" 2>/dev/null
  printf '{"ts":%s,"session_id":"%s","tool":"%s","kind":"%s","original_chars":%s,"emitted_chars":%s}\n' \
    "$(date +%s)" "${SID:-unknown}" "${TOOL:-unknown}" "$1" "${2:-0}" "${3:-0}" \
    >>"$HOME/.suit/token-savings.jsonl" 2>/dev/null
  return 0
}

INPUT="$(cat)"
[ -n "$INPUT" ] || pass_through

if [ "${SUIT_POSTTOOL_DEBUG:-0}" = "1" ]; then
  mkdir -p "$HOME/.suit" 2>/dev/null
  printf '%s\n' "$INPUT" >>"$HOME/.suit/posttool-debug.jsonl" 2>/dev/null
fi

# Bench kill-switch: disable every rewrite (and the cache lifecycle ops)
# per-process, leaving the installed hook entries untouched. Checked after the
# stdin read (so the hook's writer never takes a SIGPIPE) and after the debug
# tee (diagnostics work regardless of the switch).
[ "${SUIT_TOKEN_FILTERS:-on}" = "off" ] && pass_through

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

# Emit an updatedToolOutput payload that mirrors the original tool_response's
# shape with only its content-bearing field replaced by $new. Claude Code
# SILENTLY IGNORES a bare-string updatedToolOutput for tools whose response is
# an object (verified empirically on 2.1.208: the full result still reached
# the model) — the replacement must be the same shape the tool produced.
# Observed shapes: Bash {stdout, stderr, ...} (stderr is folded, labeled, into
# the replacement stdout), Grep {content, numLines, ...}, Glob {filenames,
# numFiles, ...}, Read {type, file: {content, numLines, ...}}. An unrecognized
# shape emits nothing → the caller passes through.
REPLACE_JQ='
  def replaced($new):
    .tool_response as $r
    | if ($r | type) == "string" then $new
      elif ($r | type) == "object" then
        (if ($r.stdout? != null) then ($r | .stdout = $new | .stderr = "")
         elif ($r.output? != null) then ($r | .output = $new)
         elif ($r.content? != null) then
           ($r | .content = $new
               | (if (.numLines? != null) then .numLines = ($new | split("\n") | length) else . end))
         elif ($r.file?.content? != null) then
           ($r | .file.content = $new
               | (if (.file.numLines? != null) then .file.numLines = ($new | split("\n") | length) else . end))
         elif ($r.filenames? != null) then
           ($r | .filenames = ($new | split("\n"))
               | (if (.numFiles? != null) then .numFiles = (.filenames | length) else . end))
         else null end)
      else null end;
  replaced($new) as $updated
  | if $updated == null then empty
    else {hookSpecificOutput: {hookEventName: "PostToolUse", updatedToolOutput: $updated}} end
'

# Extract the result text defensively (used by the savings meter and the
# compression cut): the hook docs don't pin tool_response's shape per tool, so
# accept a plain string or the known object fields — anything else yields empty
# and the affected behavior passes through. A Bash object result keeps its
# stderr (labeled) so a failure's diagnostics survive an elision. The field
# priority here matches replaced() above, so the text measured is the text
# that gets replaced.
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

# --- Token-ignore (Grep/Glob result filtering) ---------------------------------
# Drops result lines under the repo's .claude/token-ignore prefixes. Runs
# before dedup/compression and, when it rewrites, exits — the marker already
# tells the model how to widen if the hidden tail matters, so a second
# elision pass over the filtered remainder isn't worth the added complexity.
if [ "$IGNORE" = "1" ] && { [ "$TOOL" = "Grep" ] || [ "$TOOL" = "Glob" ]; } && [ -n "$TEXT" ]; then
  TPATH="$(printf '%s' "$INPUT" | jq -r '.tool_input.path // empty' 2>/dev/null)"
  HOOK_CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
  START="${TPATH:-$HOOK_CWD}"
  [ -d "$START" ] || START="$(dirname "$START" 2>/dev/null)"
  # Walk up for the nearest .claude/token-ignore; none → nothing to filter.
  # TWIN: suit-token-ignore.sh walks and parses the same file for Read denies —
  # keep the walk-up, comment strip, and prefix rules byte-compatible.
  IGN_ROOT=""
  DIR="$START"
  while [ -n "$DIR" ] && [ "$DIR" != "/" ] && [ "$DIR" != "." ]; do
    if [ -f "$DIR/.claude/token-ignore" ]; then
      IGN_ROOT="$DIR"
      break
    fi
    DIR="$(dirname "$DIR")"
  done
  if [ -n "$IGN_ROOT" ]; then
    # Patterns → absolute prefixes, newline-separated.
    PREFIXES=""
    while IFS= read -r LINE; do
      LINE="${LINE%%#*}"
      # shellcheck disable=SC2001
      LINE="$(printf '%s' "$LINE" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      [ -n "$LINE" ] || continue
      case "$LINE" in
        /*) ABS="$LINE" ;;
        *)  ABS="$IGN_ROOT/$LINE" ;;
      esac
      PREFIXES="$PREFIXES$ABS
"
    done <"$IGN_ROOT/.claude/token-ignore"

    # A search explicitly rooted inside an ignored prefix is deliberate —
    # pass the whole result through.
    EXPLICIT=0
    if [ -n "$TPATH" ]; then
      while IFS= read -r P; do
        [ -n "$P" ] || continue
        case "$TPATH/" in "$P"*) EXPLICIT=1; break ;; esac
      done <<PREF_EOF
$PREFIXES
PREF_EOF
    fi

    if [ "$EXPLICIT" = "0" ] && [ -n "$PREFIXES" ]; then
      FILTERED="$(jq -cn --arg text "$TEXT" --arg prefixes "$PREFIXES" '
        ($prefixes | split("\n") | map(select(length > 0))) as $ps
        | ($text | split("\n")) as $lines
        | ($lines | map(select(
            (. as $l | $ps | any(. as $p | $l | startswith($p))) | not
          ))) as $kept
        | {dropped: (($lines | length) - ($kept | length)),
           kept: ($kept | join("\n"))}
      ' 2>/dev/null)"
      DROPPED="$(printf '%s' "$FILTERED" | jq -r '.dropped // 0' 2>/dev/null)"
      if [ "$DROPPED" -gt 0 ] 2>/dev/null; then
        KEPT="$(printf '%s' "$FILTERED" | jq -r '.kept // ""' 2>/dev/null)"
        IGN_MARKER="[suit token-ignore: hid $DROPPED $TOOL result line(s) under the prefixes in $IGN_ROOT/.claude/token-ignore — pass an explicit path inside an ignored directory to include them.]"
        if [ -n "$KEPT" ]; then
          NEW="$KEPT
$IGN_MARKER"
        else
          NEW="$IGN_MARKER"
        fi
        OUT="$(printf '%s' "$INPUT" | jq -c --arg new "$NEW" "$REPLACE_JQ" 2>/dev/null)"
        if [ -n "$OUT" ]; then
          log_saving ignore "${#TEXT}" "${#NEW}"
          printf '%s' "$OUT"
          exit 0
        fi
      fi
    fi
  fi
fi

# --- Read-dedup (before compression, so a stub is never elided) ---------------
if [ "$DEDUP" = "1" ] && [ "$TOOL" = "Read" ] && [ -n "$SID" ]; then
  FILE="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
  # Only full-file reads participate: an offset past the top or any limit is a
  # deliberate range read — pass it through and never track it.
  # TWIN: the identical jq test lives in suit-token-ignore.sh; change both.
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
        OUT="$(printf '%s' "$INPUT" | jq -c --arg new "$STUB" "$REPLACE_JQ" 2>/dev/null)"
        [ -n "$OUT" ] || pass_through
        log_saving dedup "${#TEXT}" "${#STUB}"
        printf '%s' "$OUT"
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

# The result text was extracted up top; an unrecognized shape passes through.
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

OUT="$(printf '%s' "$INPUT" | jq -c --arg new "$ELIDED" "$REPLACE_JQ" 2>/dev/null)"
[ -n "$OUT" ] || pass_through
log_saving compress "$SIZE" "${#ELIDED}"
printf '%s' "$OUT"

exit 0
