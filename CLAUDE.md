# CLAUDE.md

Guidance for coding agents working in this repository. This file is the source of truth.

Suit (**S**top **U**sing **I**DE **T**erminal) is a personal macOS app growing from a terminal
into a vibe-coding-first cockpit for codebase work. It's a native AppKit bundle whose windows
host split trees of panes displaying browser-style tabs — terminals (interactive `/bin/zsh -l -i`
on SwiftTerm's pty), file viewers, diffs, and other `PaneContent` implementations. `README.md`
has the overview; `docs/features.md` is the full shipped-behavior reference.

## Rules that apply before your first tool call

Assume other Claude Code sessions are working in this repo right now. They switch branches,
stage files, and commit under you with no warning. Every rule here exists because the failure it
prevents has already happened.

- **Create a worktree before any other action.** Every task gets its own (`EnterWorktree`, or
  `git worktree add -b feature/tab-drag .claude/worktrees/tab-drag main`). No size threshold —
  a one-line fix and a doc typo included. Name it after the task; two agents that both pick
  `wip` collide. `.claude/worktrees/` is git-ignored.
- **Never touch the shared checkout at `~/Projects/suit`.** No edits, commits, merges,
  checkouts, or builds — it's read-only for orientation. If you dirty it, back up the diff,
  restore it clean, and restart inside a worktree.
- **Ask which branch the work merges into before implementing**, not after. Never assume `main`.
  Moving work off the wrong base is expensive.
- **Don't push, force-push, or hard-reset `main`** unless asked. To integrate, merge `main`
  into your branch and resolve there.
- **To land on `main`**: branch in a worktree, then merge that branch in. `git worktree add
  <path> main` fails when the shared checkout is on `main` — git refuses one branch in two
  worktrees. Merge from a task branch instead.
- Exit with `keep` to persist the worktree, `remove` once merged or abandoned.

A worktree isolates the repo, not everything a build touches. Anything at a hardcoded path
outside it is shared with every running agent:

- Give quick-iterate `swiftc` builds a task-specific output path (`/tmp/suit-shell-$TASK`), never
  a fixed one: two agents racing on one binary means you can run someone else's build and never
  notice. `design/render-reference.sh` hardcodes `/tmp/suit-design-reference`, so it races the
  same way and you can't parameterize it without editing the script — don't run it concurrently
  with another session's render.
- `./build.sh` (writes `build/` under your worktree) and `scripts/test.sh` (sandboxes `$HOME`)
  are safe. The real app's `~/.suit/` state is **not** sandboxed — two agents running
  `build/Suit.app` share it.

## Build & run

```
./build.sh                        # builds swift/, assembles build/Suit.app
open build/Suit.app               # launch like a normal Mac app
```

To iterate without assembling the bundle:

```
swiftc -O swift/Sources/suit/*.swift \
  $(find swift/Vendor/SwiftTerm -name '*.swift') -o /tmp/suit-shell-$TASK && /tmp/suit-shell-$TASK
```

**No SwiftPM, no Xcode project.** This machine runs a beta Xcode CLT (no full Xcode.app) on
which `swift build` / `swift package` fail to link even an empty manifest; plain `swiftc` is
unaffected. So SwiftTerm is vendored as source (`swift/Vendor/SwiftTerm/`) and `build.sh`
compiles everything directly. Don't run `xcode-select --install`, create a `.xcodeproj`, or
reintroduce SwiftPM without checking. Vendor new Swift dependencies the same way.

## Testing

No XCTest target. Pure, UI-free logic is verified by **standalone harnesses** — each compiles
the relevant Foundation-only file(s) against a small assertion driver and runs it.

```
scripts/test.sh                   # fast suite, ~seconds
scripts/test.sh --all             # + the autopilot pipeline harness (~4 min)
scripts/test.sh --list            # list the harnesses
```

This is why testable logic lives in **Foundation-only files with no app dependencies** (the
`RoadmapParser` / `FeedbackRouting` / `Recipes` pattern): a pure standalone-compilable core plus
a thin AppKit half wiring it into the app. New logic follows the pattern, adds a harness, and
wires it into `HARNESSES` in `scripts/test.sh`.

UI/chrome changes are guarded by the committed reference render instead: re-run
`design/render-reference.sh` and commit `design/phase15-window.png` after a chrome change. The
render draws a live clock, so its bytes differ every run — only re-render on real chrome changes,
and expect conflicts if another session touched it.

## Architecture — the load-bearing concepts

- **Browser-tab model** (`TabStore.swift`, `PaneTabBarView.swift`): tabs are the unit; a window
  owns one ordered tab list + MRU order. Panes are viewports — each displays at most one tab;
  backgrounded tabs keep their processes running. Splitting is tab-first (⌘D, right-click, drag
  a tab to a pane edge); files are regular tabs deduped by path.
- **`PaneContent` protocol** (`PaneContent.swift`): what a pane hosts — view, focus target,
  title, appearance hooks, teardown. Implement it for a new pane kind and splits, title bars,
  focus, and drag all work unchanged.
- **Derived focus** (`Pane.swift`): the focus border is never pushed. The window controller
  KVO-observes `window.firstResponder` and repaints every pane from it in one place.
- **`~/.suit/` state** (favorites, notes, recipes, layouts, autopilot, sessions, ssh hosts):
  stores follow the `FavoritesStore` pattern — `$HOME`-resolved paths so harnesses can sandbox
  them, atomic writes, a `didUpdate` notification.
- **Claude integration** (`ClaudeSessions.swift`, `ClaudeIntegration.swift`, `scripts/claude/`):
  statusline + hook scripts write session/usage JSON under `~/.suit/`; the app watches those
  files, maps sessions to panes, and talks back into the pty via `SessionControl.send`
  (bracketed paste, delayed `\r`). Scripts install via the in-app installer, never by hand.
- **Autopilot** (`AutopilotEngine.swift` + `AutopilotScheduler` / `RoadmapParser` /
  `AutopilotStore` / `AutopilotGates` / `AutopilotPrompts`): works `ROADMAP.md` phases
  autonomously — worktree → worker session → verify against world state (never trust the Stop
  hook) → build gate → review gate → merge PR → cleanup. Budget math and roadmap parsing are
  pure, harness-tested files.
- **State restoration** (`StateRestoration.swift`): a Codable snapshot of each window's tabs,
  split tree, and viewer scrolls, captured at quit and replayed on launch. `Layouts.swift`
  reuses the machinery for named workspaces.

## File map

Everything is in `swift/Sources/suit/` unless noted.

- **App shell**: `main.swift`, `AppDelegate.swift` + `AppDelegate+*.swift` (windows, menu bar,
  palette registry, settings, global shortcuts), `TerminalWindowController.swift` + `+*.swift`
  (per-window controller), `SettingsWindowController.swift` (+ `+Sections` / `+Actions`),
  `CommandPalette.swift` (⌘K palette, ⌘P file picker), `OverlayPrompt.swift`,
  `KeyboardShortcuts.swift`, `Theme.swift` (central styling), `Broadcast.swift`,
  `UpdateCheckCore.swift` / `UpdateChecker.swift`.
- **Tabs & panes**: `TabStore.swift`, `TabSwitcherPanel.swift` (⌃Tab MRU), `Pane.swift`,
  `PaneContent.swift`, `PaneTerminalView.swift`, `PaneTabBarView.swift`, `PaneTitleBarView.swift`,
  `ProjectHeaderView.swift`, `PaneScreensaverView.swift`, `SplitOrientation.swift`,
  `StateRestoration.swift`, `Layouts.swift` + `AppDelegate+Layouts.swift`, `ProcessUtil.swift`.
- **Sidebar**: `ActivityBarView.swift` (the far-left full-height icon strip — laid out by
  `WindowRootView` *outside* the sidebar split so it survives a ⌘B collapse; it renders selection
  and reports clicks, but `SidebarView` owns the tab model), `RailIconView.swift` (one
  activity-bar icon), `SidebarView.swift` (the panel: Files / Sessions / SSH Hosts / Notes /
  Bookmarks), `FileBrowserView.swift` (+ `GitFooterView`), `SearchView.swift` (⇧⌘F),
  `FileIndex.swift`,
  `RipgrepSearch.swift` (bundled `rg --json`), `Favorites.swift`, `Notes.swift`,
  `Bookmarks.swift`, `SSHHosts.swift` / `SSHPane.swift` / `SSHHostsView.swift`.
- **Viewer & editing**: `FileViewerPane.swift` (+ `Editing`, `Symbols`, `TimeTravel`,
  `Highlighting`, `Blame`), `ViewerContainerView.swift`, `ViewerTextView.swift`,
  `LineNumberRulerView.swift`, `FileEdit.swift`, `FileWatch.swift` / `FileWatcher.swift`
  (live on-disk-change reload shared by all four file-backed pane kinds), `FileTimeTravel.swift`,
  `SyntaxHighlighter.swift`, `MinimapView.swift`, `SymbolIndexCore.swift` / `SymbolIndex.swift`
  (ctags go-to-definition), `ReferencesPane.swift`. Other pane kinds: `MarkdownPane.swift` +
  `MarkdownRenderer.swift`, `ImagePane.swift`, `PDFPane.swift`.
- **Git & GitHub**: `GitStatus.swift`, `GitBlame.swift`, `GitView.swift` (review surface, opened
  via the palette — no sidebar tab) + `+Feedback` / `+PRInbox`, `GitBranches.swift`
  (`GitHubCLI` gh wrapper, degrades gracefully with no gh), `DiffParser.swift`, `DiffPane.swift`,
  `CommitGraph.swift` / `CommitGraphPane.swift`, `WorktreeTasks.swift`, `WorktreeSwitcher.swift`,
  `FeedbackRouting.swift` / `FeedbackInbox.swift`, `PRReview.swift`.
- **Claude**: `ClaudeSessions.swift`, `ClaudeIntegration.swift`, `ClaudeAttention.swift`
  (notifications + Dock badge), `TranscriptPane.swift`, `ClaudeMode.swift`, `PlanParsing.swift` /
  `PlanApprovalPane.swift`, `PromptComposer.swift`, `Recipes.swift`, `TaskLaunch.swift` /
  `SubagentTree.swift`, `Activity.swift` / `ActivityRecorder.swift` /
  `ActivityFeedController.swift`, `Dictation.swift` / `DictationText.swift`,
  `NotificationSounds.swift` / `NotificationSoundCore.swift`.
- **Autopilot & fleet**: `AutopilotEngine.swift` + `+*.swift`, `AutopilotScheduler.swift`,
  `RoadmapParser.swift`, `AutopilotStore.swift`, `AutopilotGates.swift`, `AutopilotPrompts.swift`,
  `AutopilotEngineTypes.swift`, `BudgetGuardrails.swift` + `AppDelegate+Budget.swift`,
  `FleetDashboard.swift` + `FleetModel.swift`, `GoalComposition.swift`.
- **Sessions & history**: `CommandHistory.swift` + `AppDelegate+CommandHistory.swift`,
  `CheckpointTimeline.swift`, `Markers.swift`, `SlashCommands.swift`, `TranscriptSearch.swift`,
  `BackgroundTasks.swift` / `BackgroundTaskStore.swift` / `BackgroundTaskPane.swift`.
- **Repo root**: `scripts/claude/` (statusline + hook scripts, bundled by `build.sh`),
  `scripts/*.sh` (harnesses), `design/` (reference render), `Resources/Info.plist` (bundle id
  `dev.kosych.suit` — add `NS*UsageDescription` keys here when a feature needs one), `build.sh`.
- **Vendored**: `swift/Vendor/SwiftTerm/`.

For any file's full behavior, read its header region and the harness covering it — the code is
the source of truth for details.

## Conventions

- Match the surrounding code. This repo favors dense doc-comments at the top of each file
  explaining the *why*; keep that up in new files.
- A new pane kind = implement `PaneContent`. Splits, focus, and drag-rearrange follow for free.
- Pure, testable logic goes in a Foundation-only file with no app deps so a harness can compile
  it standalone.
- **Privacy invariants are load-bearing**: SSH passwords live only in the Keychain, never in
  JSON/logs/saved state; OSC 52 clipboard reads are denied. Don't regress these.
- The bundle is ad-hoc signed in `build.sh`, so TCC tracks grants against `dev.kosych.suit`, not
  Terminal.app. A rebuilt bundle re-prompts for the first Keychain read — expected.
- **Document a shipped feature in `docs/features.md`** (behavior, shortcuts, settings) as part of
  the same task. Keep `README.md` lean — Highlights, pointers into `docs/features.md` and
  `docs/development.md`, and the shortcuts table; touch it only when a change belongs there.
- **`/goal` tasks run the full loop** without asking: worktree → implement → `gh pr create`
  against `main` → `gh pr merge`, resolving conflicts until merged. Stop only when merged or
  genuinely blocked.

## Consult Fable 5 at decision gates

The advisor is a second opinion on a different model — it fails differently than you do, which
is the point. Invoke it **inline**: Agent tool, `subagent_type: general-purpose`, `model: fable`,
`run_in_background: false`. Open with *"You are the Suit advisor. Read
`<your-worktree>/.claude/agents/advisor.md` and follow it as your role."* — spell that path out
absolutely so it reads your charter, not whatever the shared checkout holds.

Don't rely on the `advisor` agent type resolving; sessions older than the file lack it, which is
expected and never a reason to skip a consult.

**Before acting** (these are irreversible, so afterwards is an autopsy):

- Destructive git that could lose work you didn't create — deleting another session's branch or
  worktree, history rewrites, purges.
- Changing or working around a rule in this file, including "just this once". Writing the
  justification *is* the trigger.
- Build tooling or dependency changes (`Package.swift`, an `.xcodeproj`, a new vendored dep,
  restructuring `build.sh`), or format changes to persisted `~/.suit/` state — old files exist
  on disk and migration is one-way.

**After implementing, before merge** — it reviews the diff, not the plan: any branch touching
`PaneContent` or `TabStore` themselves, focus derivation, or state restoration; or any diff past
~300 lines.

**Prompt contract** — a consult missing these is a ritual, not a review:

1. The exact action: the commands or the diff, not your description of them.
2. Every factual claim the decision rests on, numbered, with SHAs and absolute paths. The
   advisor re-checks each rather than taking your word.
3. Your best guess at your own blind spot ("if I'm wrong, it's probably because…").
4. The ask is **refute this**, not "what do you think?" — a neutral ask buys agreement with a
   well-written summary. "Checked X, Y, Z; found no error" is a valid, complete answer.
5. Your worktree's absolute path.

**If the advisor says don't proceed, don't silently override it** — surface the disagreement to
the user and stop. Two models disagreeing is the user's call.

**Its findings expire.** A consult takes minutes, and other sessions commit during them — the
verdict holds only for the SHAs examined. Re-verify the key facts immediately before any
irreversible command. The advisor can't see other sessions or arbitrate between them; worktree
discipline does that.

**Skip it** for mechanical work (renames, typos, docs, adding a harness to `HARNESSES`) and for
additive features following an existing pattern — *implementing* `PaneContent` for a new pane
kind needs no consult; the protocol exists so those are safe. **The skip list never overrides a
fired gate**: the line count and the file list win, and "it follows an existing pattern" is your
own classification of your own work — it can't excuse a 400-line diff. Usually 0–2 consults per
task; if you're well past that, split the task or stop consulting to avoid deciding.

## Agent tooling

- `.claude/agents/advisor.md` — the advisor charter (Fable 5); gates and contract are above.
- `.claude/commands/` — repo slash commands: `/build`, `/test`, `/render-reference`, `/orient`,
  `/find-file`.
- `.claude/settings.json` — shared permission allowlist. It deliberately does not auto-allow
  `git push` (asks) or force-push (denied).
