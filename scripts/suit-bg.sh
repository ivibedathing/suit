#!/bin/bash
# suit-bg — launch a long-running command in the background, tracked by Suit's
# background-task monitor (ROADMAP Phase 30).
#
# It runs the command detached with its stdout+stderr captured to a log file,
# and drops a small JSON record into ~/.suit/tasks/ that the monitor reads:
# command, pid, launching shell, log path, status, and (on completion) the exit
# code. The interactive prompt returns immediately — the job keeps running, and
# the monitor pane tails the log and shows running / done / failed live.
#
#   suit-bg npm run dev
#   suit-bg python -m http.server 8080
#
# No dependencies (no jq): the record is a single-line JSON object written
# atomically (temp + mv). $HOME is honored so a sandboxed harness can redirect
# both this script and the monitor to a temp home.
set -u

if [ "$#" -eq 0 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
  echo "usage: suit-bg <command> [args...]" >&2
  echo "  Runs <command> in the background, tracked by Suit's task monitor." >&2
  exit 64
fi

HOME_DIR="${HOME:-$(cd ~ && pwd)}"
TASKS_DIR="$HOME_DIR/.suit/tasks"
mkdir -p "$TASKS_DIR" || { echo "suit-bg: cannot create $TASKS_DIR" >&2; exit 1; }

id="$(date +%s)-$$-${RANDOM:-0}"
log="$TASKS_DIR/$id.log"
record="$TASKS_DIR/$id.json"
shell_pid="$PPID"
started="$(date +%s)"
: > "$log"

# Minimal JSON string escaping for the command field (backslash, quote, and the
# control characters that can appear in a command line).
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

cmd_display="$*"
cmd_json="$(json_escape "$cmd_display")"
log_json="$(json_escape "$log")"

# Writes/overwrites the record atomically. Args: pid status exitCode(may be empty).
write_record() {
  local pid="$1" status="$2" code="${3:-}"
  local exit_field="null"
  [ -n "$code" ] && exit_field="$code"
  printf '{"id":"%s","command":"%s","pid":%s,"shell":%s,"log":"%s","status":"%s","exitCode":%s,"port":null,"startedAt":%s}\n' \
    "$id" "$cmd_json" "$pid" "$shell_pid" "$log_json" "$status" "$exit_field" "$started" \
    > "$record.tmp"
  mv -f "$record.tmp" "$record"
}

# Detached watcher subshell: the command runs as *its own child* so `wait`
# yields the real exit code; output is captured to the log; the record is
# rewritten on completion. Backgrounded + disowned so the caller's prompt
# returns at once, then reparented to init when this script exits.
(
  "$@" > "$log" 2>&1 &
  child=$!
  write_record "$child" "running"
  wait "$child"
  code=$?
  if [ "$code" -eq 0 ]; then
    write_record "$child" "exited" "$code"
  else
    write_record "$child" "failed" "$code"
  fi
) &
disown 2>/dev/null || true

echo "suit-bg: tracking [$id] $cmd_display"
echo "  log: $log"
