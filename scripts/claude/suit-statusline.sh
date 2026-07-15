#!/bin/sh
# Claude Code statusLine command (wire it up in Claude Code settings as the
# statusLine command). Three jobs:
#   1. Print the status line: model + working dir (basename + branch) + 5h/weekly
#      rate-limit percentages.
#   2. Mirror the JSON to ~/.suit/claude-status.json (global usage for
#      Suit's title-bar accessory).
#   3. Merge cwd/model/usage into this session's ~/.suit/sessions file so
#      the Sessions sidebar stays fresh while Claude works (state stays
#      whatever the hooks last set; defaults to "working" for new sessions).
set -eu

# Claude Code pipes the statusline JSON in on stdin. When run by hand from a
# terminal there is no piped input, so `cat` below would block forever
# waiting for EOF — bail with usage instead.
if [ -t 0 ]; then
  echo "usage: printf '%s' '<statusline json>' | $0" >&2
  echo "(meant to be wired up as Claude Code's statusLine command, not run by hand)" >&2
  exit 2
fi

command -v jq >/dev/null 2>&1 || { echo "Suit: jq not installed"; exit 0; }

out_dir="$HOME/.suit"
sessions_dir="$out_dir/sessions"
mkdir -p "$sessions_dir"

input="$(cat)"
now="$(date +%s)"

# Global usage snapshot.
tmp=$(mktemp "$out_dir/.claude-status.XXXXXX")
printf '%s' "$input" | jq --argjson captured_at "$now" '. + {captured_at: $captured_at}' > "$tmp"
mv "$tmp" "$out_dir/claude-status.json"

# Shared by the per-session enrichment and the visible status line below.
cwd=$(printf '%s' "$input" | jq -r '.workspace.current_dir // .cwd // empty')

# Per-session enrichment.
sid=$(printf '%s' "$input" | jq -r '.session_id // empty')
if [ -n "$sid" ]; then
  model=$(printf '%s' "$input" | jq -r '.model.display_name // empty')
  # Fields that newer Claude Code versions provide; all optional (// empty).
  transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
  name=$(printf '%s' "$input" | jq -r '.session_name // empty')
  ctx=$(printf '%s' "$input" | jq -r '.context_window.used_percentage // empty')
  cost=$(printf '%s' "$input" | jq -r '.cost.total_cost_usd // empty')

  file="$sessions_dir/$sid.json"
  existing="{}"
  [ -f "$file" ] && existing=$(cat "$file" 2>/dev/null || printf '{}')
  printf '%s' "$existing" | jq -e . >/dev/null 2>&1 || existing="{}"

  tmp=$(mktemp "$sessions_dir/.session.XXXXXX")
  printf '%s' "$existing" | jq \
    --arg sid "$sid" --arg cwd "$cwd" --arg model "$model" \
    --arg transcript "$transcript" --arg name "$name" \
    --arg ctx "$ctx" --arg cost "$cost" \
    --argjson now "$now" \
    '. + {session_id: $sid, updated_at: $now}
     + (if $cwd != "" then {cwd: $cwd} else {} end)
     + (if $model != "" then {model: $model} else {} end)
     + (if $transcript != "" then {transcript_path: $transcript} else {} end)
     + (if $name != "" then {session_name: $name} else {} end)
     + (if $ctx != "" then {context_pct: ($ctx | tonumber)} else {} end)
     + (if $cost != "" then {cost_usd: ($cost | tonumber)} else {} end)
     | .state //= "working"' > "$tmp"
  mv "$tmp" "$file"
fi

# The visible status line.
model=$(printf '%s' "$input" | jq -r '.model.display_name // empty')
five=$(printf '%s' "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
week=$(printf '%s' "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')

line="$model"

# Working directory as "<dir> (<branch>)". Basename only, never the full path:
# this line lands in screenshots, and $HOME would leak the username. Parallel
# worktrees get distinct directory names, so the basename identifies them.
if [ -n "$cwd" ]; then
  where=$(basename "$cwd")
  branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  # Detached HEAD reports the literal "HEAD"; show the short sha instead.
  if [ "$branch" = "HEAD" ]; then
    branch=$(git -C "$cwd" rev-parse --short HEAD 2>/dev/null || true)
  fi
  [ -n "$branch" ] && where="$where ($branch)"
  line="$line  $where"
fi

[ -n "$five" ] && line="$line  5h: $(printf '%.0f' "$five")%"
[ -n "$week" ] && line="$line  week: $(printf '%.0f' "$week")%"
printf '%s' "$line"
