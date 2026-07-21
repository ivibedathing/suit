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
#   scripts/test.sh           # fast suite (feedback-routing, mode-plan, broadcast,
#                             #  recipes, file-edit, file-watch, activity, pr-review,
#                             #  diffparser, layouts, file-time-travel, budget,
#                             #  command-history), ~seconds
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
  "broadcast|scripts/broadcast-test.sh|fast"
  "recipes|scripts/recipes-test.sh|fast"
  "file-edit|scripts/file-edit-test.sh|fast"
  "file-watch|scripts/file-watch-test.sh|fast"
  "find-replace|scripts/find-replace-test.sh|fast"
  "editor-ops|scripts/editor-ops-test.sh|fast"
  "editor-nav|scripts/editor-nav-test.sh|fast"
  "activity|scripts/activity-test.sh|fast"
  "pr-review|scripts/pr-review-test.sh|fast"
  "diffparser|scripts/diffparser-test.sh|fast"
  "git-branch-ops|scripts/git-branch-ops-test.sh|fast"
  "storefile|scripts/storefile-test.sh|fast"
  "layouts|scripts/layouts-test.sh|fast"
  "file-time-travel|scripts/file-time-travel-test.sh|fast"
  "budget|scripts/budget-test.sh|fast"
  "command-history|scripts/command-history-test.sh|fast"
  "markdown-html|scripts/markdown-html-test.sh|fast"
  "roadmap-routing|scripts/roadmap-routing-test.sh|fast"
  "model-routing|scripts/model-routing-test.sh|fast"
  "autopilot-paths|scripts/autopilot-paths-test.sh|fast"
  "dictation|scripts/dictation-test.sh|fast"
  "themes|scripts/test-themes.sh|fast"
  "notification-sound|scripts/notification-sound-test.sh|fast"
  "update-check|scripts/update-check-test.sh|fast"
  "file-index|scripts/file-index-test.sh|fast"
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
