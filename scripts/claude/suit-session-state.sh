#!/bin/sh
# Claude Code hook → Suit session state (ROADMAP Phase 4).
#
# Usage (in Claude Code settings hooks):
#   UserPromptSubmit → suit-session-state.sh working
#   Notification     → suit-session-state.sh needs-input
#   Stop             → suit-session-state.sh done
#
# Reads the hook JSON on stdin and merges state into
# ~/.suit/sessions/<session-id>.json, which Suit's session monitor
# watches. Also records the pid of the claude process the hook belongs to
# (found by walking up the process tree) so Suit can map sessions to
# panes by pid ancestry.
set -eu

# Claude Code pipes the hook JSON in on stdin. When run by hand from a
# terminal there is no piped input, so `cat` below would block forever
# waiting for EOF — bail with usage instead.
if [ -t 0 ]; then
  echo "usage: printf '%s' '<hook json>' | $0 [working|needs-input|done]" >&2
  echo "(meant to be invoked by Claude Code hooks, not by hand)" >&2
  exit 2
fi

command -v jq >/dev/null 2>&1 || exit 0

state="${1:-working}"
dir="$HOME/.suit/sessions"
mkdir -p "$dir"

input="$(cat)"
sid=$(printf '%s' "$input" | jq -r '.session_id // empty')
[ -n "$sid" ] || exit 0
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
summary=$(printf '%s' "$input" | jq -r '.prompt // .message // empty' | head -c 120 | tr '\n' ' ')
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty')

# The claude process is an ancestor of this hook; walk up a few levels.
pid=$$
claude_pid=""
i=0
while [ "$i" -lt 8 ]; do
  pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') || break
  [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
  cmd=$(ps -o command= -p "$pid" 2>/dev/null || true)
  case "$cmd" in
    *claude*) claude_pid="$pid"; break ;;
  esac
  i=$((i + 1))
done

file="$dir/$sid.json"
existing="{}"
[ -f "$file" ] && existing=$(cat "$file" 2>/dev/null || printf '{}')
printf '%s' "$existing" | jq -e . >/dev/null 2>&1 || existing="{}"

tmp=$(mktemp "$dir/.session.XXXXXX")
printf '%s' "$existing" | jq \
  --arg sid "$sid" --arg state "$state" --arg cwd "$cwd" \
  --arg summary "$summary" --arg pid "$claude_pid" \
  --arg transcript "$transcript" \
  --argjson now "$(date +%s)" \
  '. + {session_id: $sid, state: $state, updated_at: $now}
   + (if $cwd != "" then {cwd: $cwd} else {} end)
   + (if $summary != "" then {summary: $summary} else {} end)
   + (if $pid != "" then {pid: ($pid | tonumber)} else {} end)
   + (if $transcript != "" then {transcript_path: $transcript} else {} end)' > "$tmp"
mv "$tmp" "$file"
