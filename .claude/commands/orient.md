---
description: Get oriented in the Suit codebase — the map, build/test commands, and rules
allowed-tools: Read, Bash(git status:*), Bash(git log:*), Bash(git worktree list:*)
---

Give me a quick orientation to this repo so I can start working effectively.

1. Read `AGENTS.md` (the concise front-door) and skim the file map in
   `CLAUDE.md` — do not dump them back to me, just internalize them.
2. Report the current state: `git status`, current branch, active worktrees,
   and the last few commits.
3. Read the `### Phase` headings in `ROADMAP.md` and tell me which phases are
   unclaimed (no `🚧`/`✅`/`⏸` marker) — those are available to pick up.
4. Remind me of the non-negotiables in one line each: worktree-per-task, claim
   before starting, no SwiftPM (`./build.sh` / direct `swiftc`), tests via
   `scripts/test.sh`, document shipped phases in `README.md`.
