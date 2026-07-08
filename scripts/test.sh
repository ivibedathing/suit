#!/bin/bash
# Unified logic-test runner for Suit's UI-free cores.
#
# Suit has no XCTest target (there's no SwiftPM / Xcode project — see CLAUDE.md
# "Why no SwiftPM"). Instead, the pure, app-independent logic that phases rest
# on is verified by standalone harnesses that compile just the relevant
# Foundation-only sources against a small assertion driver and run it — no app,
# no UI. This script runs them all from one place so an agent has a single
# "run the tests" command before committing a non-UI change.
#
# Usage:
#   scripts/test.sh           # fast suite (feedback-routing + mode-plan), ~seconds
#   scripts/test.sh --all     # also runs the autopilot pipeline harness (~4 min)
#   scripts/test.sh --list    # list the harnesses and exit
#   scripts/test.sh -h        # this help
#
# Exit: 0 if every harness passed, 1 if any failed or a harness is missing.
set -uo pipefail
cd "$(dirname "$0")/.."

# Each entry: "name|script|speed" (speed = fast|slow).
HARNESSES=(
  "feedback-routing|scripts/feedback-routing-test.sh|fast"
  "mode-plan|scripts/mode-plan-harness.sh|fast"
  "symbol-index|scripts/symbol-index-test.sh|fast"
  "broadcast|scripts/broadcast-test.sh|fast"
  "autopilot|scripts/autopilot-harness.sh|slow"
)

run_slow=0
case "${1:-}" in
  --all)  run_slow=1 ;;
  --list)
    printf '%-18s %-38s %s\n' "NAME" "SCRIPT" "SPEED"
    for h in "${HARNESSES[@]}"; do
      IFS='|' read -r name script speed <<<"$h"
      printf '%-18s %-38s %s\n' "$name" "$script" "$speed"
    done
    exit 0 ;;
  -h|--help)
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
    exit 0 ;;
  "") ;;
  *)
    echo "test.sh: unknown option '$1' (try -h)" >&2
    exit 1 ;;
esac

failed=0
ran=0
skipped=0
for h in "${HARNESSES[@]}"; do
  IFS='|' read -r name script speed <<<"$h"
  if [ "$speed" = "slow" ] && [ "$run_slow" -eq 0 ]; then
    echo "SKIP  $name  (slow — pass --all to include)"
    skipped=$((skipped + 1))
    continue
  fi
  if [ ! -x "$script" ]; then
    echo "FAIL  $name  (missing or not executable: $script)"
    failed=$((failed + 1))
    continue
  fi
  echo "==> $name  ($script)"
  if "$script"; then
    echo "PASS  $name"
  else
    echo "FAIL  $name  (exit $?)"
    failed=$((failed + 1))
  fi
  ran=$((ran + 1))
  echo
done

echo "----------------------------------------"
if [ "$failed" -eq 0 ]; then
  echo "OK — $ran harness(es) passed, $skipped skipped."
  exit 0
else
  echo "FAILED — $failed of $ran harness(es) failed, $skipped skipped."
  exit 1
fi
