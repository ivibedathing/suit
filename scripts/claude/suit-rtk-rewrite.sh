#!/usr/bin/env bash
# Suit rtk output-compression hook (Claude Code PreToolUse, Bash tool).
#
# Rewrites a Bash command so it runs through rtk ("Rust Token Killer"), which
# filters the command's output down to the salient part (test failures only,
# build errors only, trimmed git/ls/grep) before it reaches the model's context
# window. Installed / removed by Suit's "Compress tool output with rtk" toggle
# (see RtkHook.swift); off by default.
#
# Contract (verified against current Claude Code): stdin carries a JSON object
# with .tool_input.command; to rewrite it we print
#   {"hookSpecificOutput":{"hookEventName":"PreToolUse",
#     "permissionDecision":"allow","updatedInput":{"command":"rtk <cmd>"}}}
# and exit 0. To leave the command untouched we print nothing and exit 0.
#
# FAIL OPEN: any missing dependency (jq, rtk), unparseable input, empty command,
# or an already-wrapped command results in a clean no-op pass-through, so a
# broken compressor can never break the command Claude was going to run.
#
# Bench kill-switch: SUIT_TOKEN_FILTERS=off makes this hook a pure pass-through
# for the whole process, so an A/B benchmark (scripts/token-bench.sh) can run
# a filters-off arm without touching ~/.claude/settings.json.

# Never let an error abort into a non-zero exit that would surface to Claude.
set +e

pass_through() { exit 0; }

# jq is required to read/emit the hook JSON; without it, pass through.
command -v jq >/dev/null 2>&1 || pass_through

# Prefer the rtk Suit installed alongside this script; else fall back to PATH.
RTK=""
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
if [ -n "$SELF_DIR" ] && [ -x "$SELF_DIR/rtk" ]; then
  RTK="$SELF_DIR/rtk"
else
  RTK="$(command -v rtk 2>/dev/null)"
fi
[ -n "$RTK" ] || pass_through

INPUT="$(cat)"
[ -n "$INPUT" ] || pass_through

# Bench kill-switch (checked after the stdin read so the hook's writer never
# takes a SIGPIPE).
[ "${SUIT_TOKEN_FILTERS:-on}" = "off" ] && pass_through

CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -n "$CMD" ] || pass_through

# Don't double-wrap a command that already goes through rtk.
case "$CMD" in
  rtk\ *|*/rtk\ *) pass_through ;;
esac

# Bypass escape hatch: when full, unfiltered output is needed for one command,
# opt it out without touching the global toggle — either an "NO_RTK=1" env
# prefix or a "# nortk" marker anywhere in the command runs it unchanged.
case "$CMD" in
  NO_RTK=1|NO_RTK=1\ *) pass_through ;;
  *"# nortk"*) pass_through ;;
esac

WRAPPED="$RTK $CMD"

printf '%s' "$INPUT" | jq -n \
  --arg cmd "$WRAPPED" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "allow", updatedInput: {command: $cmd}}}' \
  2>/dev/null || pass_through

exit 0
