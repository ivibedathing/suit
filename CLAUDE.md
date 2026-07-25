# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Suit (**S**top **U**sing **I**DE **T**erminal) is a personal macOS app: a native AppKit bundle
whose windows host split trees of panes displaying browser-style tabs — terminals (interactive
`/bin/zsh -l -i` on SwiftTerm's pty), file viewers, diffs, and other `PaneContent` kinds.
`README.md` is the overview; `docs/features.md` is the full shipped-behavior reference.

## Several agents share this repo — work in a worktree

Assume other Claude Code sessions are editing this repo right now. They switch branches, stage
files, and commit under you with no warning. Sessions sharing one working tree overwrite each
other's edits and produce half-merged diffs.

- **Create a worktree before your first tool call.** Every task gets one — a one-line fix and a
  doc typo included. Name it after the task; two agents that both pick `wip` collide.

  ```sh
  git worktree add -b feature/tab-drag .claude/worktrees/tab-drag main
  ```

  `.claude/worktrees/` is git-ignored. Read-only exploration doesn't need one.
- **Never touch the shared checkout at `~/Projects/suit`** — no edits, commits, or builds. If you
  dirty it, back up the diff, restore it clean, and restart inside a worktree.
- **Ask which branch the work merges into before implementing**, not after. Never assume `main`.
- **Don't push, force-push, or hard-reset `main`.** To integrate, merge `main` into your branch.
  To land on `main`, merge your task branch in. (`git worktree add <path> main` fails when the
  shared checkout is on `main` — git refuses one branch in two worktrees. Branch instead.)

A worktree isolates the repo, not everything a build touches. Anything at a hardcoded path
outside it is shared with every running agent:

- Give quick `swiftc` builds a task-specific output path (`/tmp/suit-shell-$TASK`). With a fixed
  one, two agents race and you can run someone else's binary without noticing.
- `design/render-reference.sh` hardcodes `/tmp/suit-design-reference` and can't be parameterized
  without editing it — don't run it while another session is rendering.
- `./build.sh` (writes `build/` in your worktree) and `scripts/test.sh` (sandboxes `$HOME`) are
  safe. The running app's `~/.suit/` state is **not** sandboxed.

## Build & run

```sh
./build.sh                        # compiles swift/, assembles build/Suit.app
open build/Suit.app
```

To iterate without assembling the bundle:

```sh
swiftc -O -j $(sysctl -n hw.ncpu) swift/Sources/suit/*.swift \
  $(find swift/Vendor/SwiftTerm -name '*.swift') -o /tmp/suit-shell-$TASK && /tmp/suit-shell-$TASK
```

**Always pass `-j`.** `swiftc` plans one frontend job per file (265 here — 204 sources plus 61
vendored) and runs them *serially* by default: ~3 minutes on one core with ten idle. `-j` drops
that to ~30 s and changes nothing but scheduling. Add `-Onone` (~16 s) when you only need a
running binary — it's the wrong build for judging scroll smoothness or anything perf-shaped.

**No SwiftPM, no Xcode project.** This machine runs a beta Xcode CLT on which `swift build` fails
to link even an empty manifest; plain `swiftc` is unaffected. So SwiftTerm is vendored as source
(`swift/Vendor/SwiftTerm/`) and `build.sh` compiles everything as one module. Don't run
`xcode-select --install`, create a `.xcodeproj`, or reintroduce SwiftPM without checking. Vendor
new Swift dependencies the same way.

## Testing

No XCTest target. Pure, UI-free logic is verified by **standalone harnesses** — each compiles the
relevant Foundation-only file(s) against a small assertion driver and runs it.

```sh
scripts/test.sh                   # fast suite, ~seconds
scripts/test.sh --all             # + the autopilot pipeline harness (~2 min)
scripts/test.sh --list            # list the harnesses
scripts/editor-ops-test.sh        # one harness directly — the inner loop
```

A harness is a pair: `scripts/<name>-test.sh` (compiles + runs) and `scripts/<name>-test/main.swift`
(the assertions). New logic follows the pattern — a Foundation-only core with no app deps, plus a
thin AppKit half wiring it in (`RoadmapParser` / `FeedbackRouting` / `EditorOps`) — adds a harness,
and wires it into `HARNESSES` in `scripts/test.sh`.

`.github/workflows/swift.yml` runs `./build.sh` and `scripts/test.sh` on every PR to `main`, so a
broken or unwired harness blocks the merge.

UI/chrome changes are guarded by a committed reference render instead: re-run
`design/render-reference.sh` and commit `design/phase15-window.png`. The render draws a live clock,
so its bytes differ every run — only re-render on real chrome changes, and expect conflicts if
another session touched it.

## Architecture — the load-bearing concepts

- **Browser-tab model** (`TabStore.swift`, `PaneTabBarView.swift`): tabs are the unit; a window
  owns one ordered tab list plus MRU order. Panes are viewports — each displays at most one tab,
  and backgrounded tabs keep their processes running. Splitting is tab-first (⌘D, right-click,
  drag a tab to a pane edge); files are regular tabs deduped by path.
- **`PaneContent` protocol** (`PaneContent.swift`): what a pane hosts — view, focus target, title,
  appearance hooks, teardown. Implement it for a new pane kind and splits, title bars, focus, and
  drag all work unchanged.
- **Derived focus** (`Pane.swift`, `PaneContainerView.swift`): the focus border is never pushed.
  The window controller KVO-observes `window.firstResponder` and repaints every pane from it in
  one place.
- **`~/.suit/` state** (favorites, notes, recipes, layouts, autopilot, sessions, ssh hosts):
  stores follow the `FavoritesStore` pattern — `$HOME`-resolved paths so harnesses can sandbox
  them, atomic writes (`StoreFile.swift`), a `didUpdate` notification.
- **Claude integration** (`ClaudeSessions.swift`, `ClaudeIntegration.swift`, `scripts/claude/`):
  statusline and hook scripts write session/usage JSON under `~/.suit/`; the app watches those
  files, maps sessions to panes, and talks back into the pty via `SessionControl.send` (bracketed
  paste, delayed `\r`). Scripts install via the in-app installer, never by hand.
- **Autopilot** (`AutopilotEngine.swift` + `AutopilotScheduler` / `RoadmapParser` / `AutopilotStore`
  / `AutopilotGates` / `AutopilotPrompts`): works `ROADMAP.md` phases autonomously — worktree →
  worker session → verify against world state (never trust the Stop hook) → build gate → review
  gate → merge PR → cleanup. `ROADMAP.md`'s heading grammar is load-bearing; `RoadmapParser.swift`
  defines it. Budget math and roadmap parsing are pure, harness-tested files.
- **State restoration** (`StateRestoration.swift`): a Codable snapshot of each window's tabs, split
  tree, and viewer scrolls, captured at quit and replayed on launch. `Layouts.swift` reuses the
  machinery for named workspaces.

## Where things live

Everything is in `swift/Sources/suit/` (flat, no subdirectories). Files are named after what they
do, so `rg` finds a subsystem faster than a map can list it — and each file opens with a dense
doc-comment explaining the *why*, which is the real reference.

A multi-file subsystem splits as `Foo.swift` + `Foo+Aspect.swift` (`AppDelegate+*`,
`TerminalWindowController+*`, `FileViewerPane+*`, `AutopilotEngine+*`, `DiffPane+*`, `GitView+*`).
Start at the base file. Rough grouping:

| Area | Entry points |
| --- | --- |
| App shell | `main.swift`, `AppDelegate.swift`, `TerminalWindowController.swift`, `CommandPalette.swift`, `Theme.swift` + `ThemeStore.swift` |
| Tabs & panes | `TabStore.swift`, `Pane.swift`, `PaneContent.swift`, `PaneTabBarView.swift`, `StateRestoration.swift` |
| Sidebar | `ActivityBarView.swift` (icon strip, laid out by `WindowRootView` *outside* the sidebar split so it survives ⌘B), `SidebarView.swift` (owns the tab model), `FileBrowserView.swift`, `SearchView.swift`, `RipgrepSearch.swift` |
| Viewer & editing | `FileViewerPane.swift`, `EditorOps.swift`, `FindReplace.swift`, `CodeFolding.swift`, `SymbolIndex.swift`, `SyntaxHighlighter.swift`, `MarkdownPane.swift` |
| Git & GitHub | `GitStatus.swift`, `GitView.swift`, `DiffPane.swift`, `DiffParser.swift`, `GitBranches.swift` (gh wrapper, degrades without gh), `WorktreeTasks.swift` |
| Claude | `ClaudeSessions.swift`, `ClaudeIntegration.swift`, `TranscriptPane.swift`, `ModelRouting.swift`, `Recipes.swift`, `Dictation.swift` |
| Autopilot & fleet | `AutopilotEngine.swift`, `AutopilotManager.swift` (several autopilots at once), `FleetDashboard.swift`, `BudgetGuardrails.swift` |
| Repo root | `build.sh`, `ROADMAP.md` (Autopilot steers off it), `scripts/claude/` (bundled hooks), `scripts/*.sh` (harnesses), `design/`, `Resources/Info.plist` (bundle id `dev.kosych.suit`) |

## Conventions

- Match the surrounding code, including the dense why-focused header comments.
- A new pane kind = implement `PaneContent`. Splits, focus, and drag follow for free.
- Pure, testable logic goes in a Foundation-only file with no app deps so a harness can compile it
  standalone.
- **Privacy invariants are load-bearing**: SSH passwords live only in the Keychain, never in
  JSON/logs/saved state; OSC 52 clipboard reads are denied. Don't regress these.
- The bundle is ad-hoc signed in `build.sh`, so TCC tracks grants against `dev.kosych.suit`. A
  rebuilt bundle re-prompts for the first Keychain read — expected.
- **Document a shipped feature in `docs/features.md`** (behavior, shortcuts, settings) in the same
  task. Keep `README.md` lean — Highlights, pointers, and the shortcuts table.
- A prompt starting with **`/goal`** arrives from the app's "Set as Goal" gesture
  (`GoalComposition.swift` types it into a session's pty — it is not a `.claude/commands/` file).
  Those run the full loop without asking: worktree → implement → `gh pr create` against `main` →
  `gh pr merge`, resolving conflicts until merged. Stop only when merged or genuinely blocked.
- `.claude/settings.json` is a shared permission allowlist. It deliberately does not auto-allow
  `git push` (asks) or force-push (denied).

## Get a second opinion at decision gates

Consult a different model — it fails differently than you do, which is the point. Agent tool,
`subagent_type: general-purpose`, `model: fable`, `run_in_background: false`. Open with *"You are
the Suit advisor: an adversarial reviewer whose job is to refute, not agree. Re-check every claim
against the repo rather than taking my word."*

**Before acting** (these are irreversible, so afterwards is an autopsy): destructive git that
could lose work you didn't create; changing or working around a rule in this file (writing the
justification *is* the trigger); build-tooling or dependency changes; format changes to persisted
`~/.suit/` state. **After implementing, before merge**: any diff touching `PaneContent`,
`TabStore`, focus derivation, or state restoration — or any diff past ~300 lines. Skip it for
mechanical work and additive features following an existing pattern, but the skip list never
overrides a fired gate: the line count and the file list win.

Give it the exact diff or commands (not your description), every factual claim numbered with SHAs
and absolute paths, your best guess at your own blind spot, and your worktree's absolute path. The
ask is **refute this**, not "what do you think?" — a neutral ask buys agreement with a well-written
summary. Findings expire: other sessions commit during a consult, so re-verify before anything
irreversible. **If it says don't proceed, surface the disagreement and stop** — two models
disagreeing is the user's call.
