---
description: Run the UI-free logic harnesses via scripts/test.sh
argument-hint: "[--all]"
allowed-tools: Bash(scripts/test.sh:*), Bash(./scripts/test.sh:*), Read
---

Run `scripts/test.sh $ARGUMENTS` from the repo root and summarize the result.

`scripts/test.sh` runs Suit's standalone logic harnesses — the pure,
app-independent cores compiled against small assertion drivers (no app, no UI).
There is no XCTest target; these harnesses are the automated tests.

- No arguments → the fast suite (feedback-routing + mode-plan, ~seconds).
- `--all` → also runs the autopilot pipeline harness (~2 minutes).
- `--list` → list the harnesses without running.

If a harness fails, show its failing assertions and fix the underlying logic —
never edit an assertion just to make it pass unless the spec genuinely changed.
