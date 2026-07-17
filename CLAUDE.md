# CLAUDE.md

Full guidance lives in **`AGENTS.md`** — the build/test commands, the architecture and file map,
and the rest of the workflow rules. Read it before doing anything else.

The rules below are repeated here, out of `AGENTS.md`, because they have to be obeyed *before*
the first tool call — by the time you have read your way down to `AGENTS.md`'s Workflow section
you may already have clobbered another session.

## Several agents run against this repo at once

Assume, always, that other Claude Code sessions are working in this repository right now. They
switch branches, stage files, and commit under you with no warning. Nothing below is a style
preference; each rule is here because the failure it prevents has already happened.

- **Create a worktree first — before any other action.** Every task gets its own
  (`EnterWorktree`, or `git worktree add`). This includes tasks that look too small to bother:
  a one-line fix, a doc typo, "just merge this branch". There is no size threshold, because the
  clobbering has nothing to do with how big your change is.
- **Never touch the shared checkout at `~/Projects/suit`.** No edits, no `git add`, no `commit`,
  no `merge`, no `checkout`, no builds. It is read-only for orientation. A concurrent session
  changing branches mid-merge will silently destroy your index and your in-progress work.
- **Name the worktree and branch after the task**, e.g.
  `git worktree add -b feature/tab-drag .claude/worktrees/tab-drag main`. Two agents that both
  pick `wip` or `fix` collide in the branch namespace; a task-specific name never does.
  `.claude/worktrees/` is git-ignored — keep worktrees there.
- **Ask which branch the work merges into before implementing, not after.** Parallel branches
  land in different places: `main`, a feature branch, another session's branch. Never assume
  `main`. Once the work is built on the wrong base, moving it is expensive.
- **Don't push, force-push, or hard-reset `main`** unless explicitly asked. To integrate, merge
  `main` into your branch and resolve there.
- **Exit with `keep`** to persist the worktree, `remove` once it is merged or abandoned.

If you catch yourself dirtying the shared checkout, stop: back up the diff, restore the checkout
clean, and restart the work inside a worktree.

## Shared paths collide between sessions — don't use fixed ones

A worktree isolates the *repo*, not everything a build touches. Anything at a hardcoded path
outside your worktree is shared with every other running agent:

- The quick-iterate `swiftc` recipe in `AGENTS.md` writes `/tmp/suit-shell`, and
  `design/render-reference.sh` writes `/tmp/suit-design-reference`. Two agents building at once
  race on the same binary — you can run the other session's build and never notice. Append
  something task-specific (`/tmp/suit-shell-tab-drag`) or use `mktemp`.
- `./build.sh` is safe: it writes `build/` relative to *your* worktree root.
- `scripts/test.sh` harnesses are safe: they sandbox `$HOME`, so `~/.suit/` state is per-run.
- The app's own `~/.suit/` state (favorites, sessions, autopilot, layouts) is **not** sandboxed
  when you launch the real app. Two agents running `build/Suit.app` share it.
- `design/phase15-window.png` is a committed artifact and the render is nondeterministic (it
  draws a live clock), so it differs on every run. Only re-render when you actually changed
  chrome, and expect merge conflicts if another session touched it too.

## Consult Fable 5 before critical decisions

Use the **`advisor`** subagent (`.claude/agents/advisor.md`, pinned to Fable 5) as a second
opinion — an advisor and reviewer, not a delegate. It runs on a different model, so it fails
differently than you do, which is the whole point of asking it.

Ask it before decisions that are expensive to reverse:

- Architectural choices — a new pane kind, a change to the tab/pane model, moving logic into the
  Go sidecar, anything touching `PaneContent` or `TabStore`.
- Changes to the load-bearing invariants in `AGENTS.md`: derived focus, the no-SwiftPM
  constraint, the Foundation-only-file testing pattern, the privacy rules (Keychain-only SSH
  passwords, OSC 52 denied).
- Before merging a non-trivial branch, and before any destructive or irreversible git operation.
- When you are about to work around a constraint rather than satisfy it — that is usually the
  moment the design is wrong.

Weigh what it says and decide yourself; it advises, it does not approve. Skip it for mechanical
work — renames, typos, docs, adding a harness to `HARNESSES`.
