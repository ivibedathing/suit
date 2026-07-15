---
description: Get oriented in the Suit codebase — the map, build/test commands, and rules
allowed-tools: Read, Bash(git status:*), Bash(git log:*), Bash(git worktree list:*)
---

Give me a quick orientation to this repo so I can start working effectively.

1. Read `AGENTS.md` (the full agent guidance, including the file map) — do not
   dump it back to me, just internalize it.
2. Report the current state: `git status`, current branch, active worktrees,
   and the last few commits.
3. Remind me of the non-negotiables in one line each: worktree-per-task, no
   SwiftPM (`./build.sh` / direct `swiftc`), tests via `scripts/test.sh`,
   document shipped features in `README.md`.
