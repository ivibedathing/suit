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

## Consult Fable 5 at decision gates

The advisor is a second opinion on a different model — it fails differently than you do, which
is the whole point of asking it.

**Invoke it inline.** Agent tool: `subagent_type: general-purpose`, `model: fable`,
`run_in_background: false` (a background consult before an irreversible action invites acting
before the verdict lands). Open the prompt with: *"You are the Suit advisor. Read
`<your-worktree>/.claude/agents/advisor.md` and follow it as your role."* — spell that path out
absolutely, so it reads your charter rather than whatever the shared checkout currently holds.

Do **not** depend on the `advisor` agent type resolving. Claude Code loads the agent registry at
session start, so every session older than the file lacks it — that is the expected state, not a
malfunction, and "advisor wasn't available" is never a reason to skip a consult. Reading the
charter from the committed file also keeps the advisor's instructions out of your control.

**Consult BEFORE acting** — these are irreversible, so afterwards is an autopsy:

- Destructive git that could lose work you didn't create: deleting another session's branch or
  worktree, history rewrites, purges.
- Changing or working around a rule in `AGENTS.md` — including "just this once". Writing the
  justification for the exception *is* the trigger.
- Build tooling or dependency changes: `Package.swift`, an `.xcodeproj`, a new vendored dep,
  restructuring `build.sh`. Same for format changes to persisted `~/.suit/` state — old files
  exist on disk and migration is one-way.

**Consult AFTER implementing, before merge** — it reviews the diff, not the plan:

- A branch touching the `PaneContent` protocol or `TabStore` *themselves*, focus derivation, or
  state restoration — or any diff past ~300 lines. Architecture gets reviewed as real code in
  your worktree, not as a pre-flight description.

**Prompt contract** — a consult missing these is a ritual, not a review:

1. The exact action: the commands or the diff, not your description of them.
2. Every factual claim the decision rests on, numbered, with SHAs and absolute paths. The
   advisor re-checks each against the repo rather than taking your word for anything checkable.
3. Your best guess at your own blind spot ("if I'm wrong, it's probably because…").
4. The ask is **refute this**, not "what do you think?" — a neutral ask buys agreement with a
   well-written summary. "Checked X, Y, Z; found no error" is a valid, complete answer.
5. Your worktree's absolute path — the advisor must read your tree and your copy of this
   charter, not the shared checkout that other sessions move under it.

**If the advisor says don't proceed, don't silently override it** — surface the disagreement to
the user and stop. Two models disagreeing is the user's call, not yours. It advises rather than
approves, but that is not license to ignore the one signal the mechanism exists to produce.

**Its findings expire.** A consult takes minutes, and other sessions commit during them — the
verdict holds only for the SHAs examined. Re-verify the key facts (are the SHAs still what the
advisor saw?) immediately before any irreversible command. The advisor cannot see other sessions
and cannot arbitrate between them; worktree discipline does that.

Skip it for mechanical work (renames, typos, docs, adding a harness to `HARNESSES`) and for
additive features that follow an existing pattern — *implementing* `PaneContent` for a new pane
kind needs no consult; the protocol exists so those are safe. **The skip list never overrides a
fired gate**: the line count and the file list win, and "it follows an existing pattern" is your
own classification of your own work — it cannot excuse a 400-line diff. Usually 0–2 consults per
task; if you're well past that, split the task or stop consulting to avoid deciding.
