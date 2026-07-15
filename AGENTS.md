# AGENTS.md

Guidance for coding agents (Claude Code and others) working in this repository.
This is the source of truth — `CLAUDE.md` is just a pointer here.

## What this is

Suit (**S**top **U**sing **I**DE **T**erminal) is a personal macOS app growing from a terminal
into a vibe-coding-first cockpit for codebase work. It's a
native AppKit app bundle whose windows host split trees of panes displaying browser-style tabs —
terminals (interactive `/bin/zsh -l -i` on SwiftTerm's pty), file viewers, diffs, and other
`PaneContent` implementations. Swift/AppKit is the product/UI layer; heavy non-UI logic may move
to a Go sidecar if it outgrows Swift. See `README.md` for the overview and `docs/features.md`
for the full shipped-behavior reference.

## Build & run

```
./build.sh                        # builds swift/, assembles build/Suit.app
open build/Suit.app               # launch like a normal Mac app
```

There is no Xcode project. To iterate without assembling the bundle:

```
swiftc -O swift/Sources/suit/*.swift \
  $(find swift/Vendor/SwiftTerm -name '*.swift') -o /tmp/suit-shell && /tmp/suit-shell
```

### Why no SwiftPM

This machine runs a beta Xcode CLT (no full Xcode.app) on which `swift build` / `swift package`
fail to link even an empty package's manifest; plain `swiftc` is unaffected. So SwiftTerm is
vendored as source (`swift/Vendor/SwiftTerm/`) and everything compiles directly via `swiftc` in
`build.sh`. Do not run `xcode-select --install`, create a `.xcodeproj`, or reintroduce
Xcode/SwiftPM tooling without checking. Vendor any new Swift dependency's source the same way.

## Testing

No XCTest target. Pure, UI-free logic is verified by **standalone harnesses**: each compiles the
relevant Foundation-only source file(s) against a small assertion driver and runs it.

```
scripts/test.sh                   # fast suite, ~seconds
scripts/test.sh --all             # + the autopilot pipeline harness (~4 min)
scripts/test.sh --list            # list the harnesses
```

This is why testable logic lives in **Foundation-only files with no app dependencies** (the
`RoadmapParser` / `FeedbackRouting` / `Recipes` pattern): a pure, standalone-compilable core file
plus a thin AppKit half that wires it into the app. When you add such logic, follow the pattern,
add a harness script for it, and wire it into the `HARNESSES` list in `scripts/test.sh`.

UI/chrome changes are guarded by the committed reference render instead: re-run
`design/render-reference.sh` and commit the updated `design/phase15-window.png` after any chrome
change so visual drift shows up in review diffs.

## Architecture — the load-bearing concepts

- **Browser-tab model** (`TabStore.swift`, `TabStripView.swift`): tabs are the unit; a window
  owns one ordered tab list + MRU order. Panes are viewports — each displays at most one tab;
  backgrounded tabs keep their processes running. Splitting is tab-first (⌘D, strip
  right-click, drag a tab to a pane edge); files are regular tabs deduped by path.
- **`PaneContent` protocol** (`PaneContent.swift`): what a pane hosts (view, focus target, title,
  appearance hooks, teardown). New pane kinds (viewer, diff, transcript, references, commit
  graph, plan approval…) implement it; splits, title bars, focus, and drag all work unchanged.
- **Derived focus** (`Pane.swift`): the focus border is never pushed — the window controller
  KVO-observes `window.firstResponder` and repaints every pane from it in one place.
- **`~/.suit/` state** (favorites, notes, recipes, layouts, autopilot, sessions, ssh hosts):
  stores follow the `FavoritesStore` pattern — `$HOME`-resolved paths (so harnesses can sandbox
  them), atomic writes, a `didUpdate` notification. SSH passwords live only in the Keychain.
- **Claude integration** (`ClaudeSessions.swift`, `ClaudeIntegration.swift`,
  `scripts/claude/`): statusline + hook scripts write session/usage JSON under `~/.suit/`;
  the app watches those files, maps sessions to panes, and talks back into the pty via
  `SessionControl.send` (bracketed paste, delayed `\r`). Scripts are installed via the
  in-app installer, never wired by hand.
- **Autopilot** (`AutopilotEngine.swift` + `AutopilotScheduler` / `RoadmapParser` /
  `AutopilotStore` / `AutopilotGates` / `AutopilotPrompts`): works through `ROADMAP.md` phases
  autonomously — worktree → worker session → verify against world state (never trust the Stop
  hook) → build gate → review gate → merge PR → cleanup. The scheduler's budget math and the
  roadmap parsing are pure, harness-tested files.
- **State restoration** (`StateRestoration.swift`): a Codable snapshot of every window's tab
  list, split tree, and viewer scrolls, captured at quit and replayed on launch;
  `Layouts.swift` reuses the same machinery for named workspaces.

## File map

Everything lives in `swift/Sources/suit/` unless noted. Roughly by area:

- **App shell**: `main.swift` (entry point), `AppDelegate.swift` + its many `AppDelegate+*.swift`
  extensions (windows, menu bar, palette command registry, settings persistence, global
  shortcuts), `TerminalWindowController.swift` + `TerminalWindowController+*.swift` (the per-window
  controller — open tabs, panes, sidebar, state, tab-store delegate), `SettingsWindowController.swift`
  (+ `+Sections` / `+Actions`), `CommandPalette.swift` (⌘K palette, also ⌘P file picker),
  `OverlayPrompt.swift`, `KeyboardShortcuts.swift`, `Theme.swift` (central styling), `Broadcast.swift`
  (⌘-typing to many terminals at once), `UpdateCheckCore.swift` / `UpdateChecker.swift` (GitHub
  release update check — notification + download offer; user installs the .dmg).
- **Tabs & panes**: `TabStore.swift`, `TabStripView.swift`, `TabItemView.swift`,
  `TabSwitcherPanel.swift` (⌃Tab MRU), `Pane.swift`, `PaneContent.swift`, `PaneTerminalView.swift`,
  `PaneTabBarView.swift`, `PaneTitleBarView.swift`, `RootHeaderView.swift`, `PaneScreensaverView.swift`,
  `SplitOrientation.swift`, `StateRestoration.swift`, `Layouts.swift` + `AppDelegate+Layouts.swift`,
  `ProcessUtil.swift`.
- **Sidebar**: `SidebarView.swift` (icon rail: Files / Bookmarks / SSH Hosts / Notes),
  `FileBrowserView.swift` (tree + `GitFooterView` branch/worktree switcher),
  `SearchView.swift` (⇧⌘F), `FileIndex.swift` (git-aware file list behind ⌘P and the browser),
  `RipgrepSearch.swift` (bundled `rg --json`), `Favorites.swift` (recent project roots),
  `Notes.swift`, `Bookmarks.swift`, `SSHHosts.swift` / `SSHPane.swift` / `SSHHostsView.swift`.
- **Viewer & editing**: `FileViewerPane.swift` (+ `Editing`, `Symbols`, `TimeTravel`,
  `Highlighting`, `Blame` extensions), `ViewerContainerView.swift`, `ViewerTextView.swift`,
  `LineNumberRulerView.swift`, `FileEdit.swift`, `FileTimeTravel.swift`, `SyntaxHighlighter.swift`,
  `MinimapView.swift`, `SymbolIndexCore.swift` / `SymbolIndex.swift` (ctags go-to-definition),
  `ReferencesPane.swift`. Other pane kinds: `MarkdownPane.swift`, `ImagePane.swift`,
  `PDFPane.swift`.
- **Git & GitHub**: `GitStatus.swift`, `GitBlame.swift`, `GitView.swift` (review surface, shown
  via the palette — no sidebar rail tab) + `GitView+Feedback.swift` / `GitView+PRInbox.swift`,
  `GitBranches.swift` (`GitHubCLI` gh wrapper with graceful no-gh degradation),
  `DiffParser.swift`, `DiffPane.swift`, `CommitGraph.swift` / `CommitGraphPane.swift`,
  `WorktreeTasks.swift`, `WorktreeSwitcher.swift`, `FeedbackRouting.swift` /
  `FeedbackInbox.swift`, `PRReview.swift`.
- **Claude**: `ClaudeSessions.swift`, `ClaudeIntegration.swift`, `ClaudeAttention.swift`
  (notifications + Dock badge), `TranscriptPane.swift`, `ClaudeMode.swift`,
  `PlanParsing.swift` / `PlanApprovalPane.swift`, `PromptComposer.swift`, `Recipes.swift`,
  `TaskLaunch.swift` / `SubagentTree.swift`, `Activity.swift` / `ActivityRecorder.swift` /
  `ActivityFeedController.swift`, `Dictation.swift` / `DictationText.swift` (push-to-talk
  dictation), `NotificationSounds.swift` / `NotificationSoundCore.swift` (attention sounds).
- **Token cost & hooks**: the token-cost campaign's pure cores, each paired with a hook or
  bench script — `RtkHook.swift` (rtk Bash-output compression rewrite), `PostToolHook.swift`
  (PostToolUse compress/dedup filter, `scripts/claude/suit-posttool-filter.sh`),
  `TokenIgnoreHook.swift` (`.claude/token-ignore` read firewall,
  `scripts/claude/suit-token-ignore.sh`), `TokenSavings.swift` (savings ledger + meter),
  `CacheStats.swift` / `CacheStatsGuard.swift` (prompt-cache hit-rate meter),
  `CompactGuardrails.swift` / `CompactGuard.swift` (auto-/compact guardrails),
  `ShellInjection.swift` (run_silent shell helpers), `ClaudeAPISettings.swift` (per-launch
  API env tuning); benchmarks in `scripts/token-*.sh` / `scripts/rtk-bench.sh`.
- **Autopilot & fleet**: `AutopilotEngine.swift` + `AutopilotEngine+*.swift`,
  `AutopilotScheduler.swift`, `RoadmapParser.swift`, `AutopilotStore.swift`, `AutopilotGates.swift`,
  `AutopilotPrompts.swift`, `AutopilotEngineTypes.swift`, `BudgetGuardrails.swift` +
  `AppDelegate+Budget.swift`, `FleetDashboard.swift` (fleet-supervision dashboard),
  `GoalComposition.swift` (`/goal` task composition).
- **Sessions & history**: `CommandHistory.swift` + `AppDelegate+CommandHistory.swift`,
  `CheckpointTimeline.swift`, `Markers.swift`, `SlashCommands.swift`, `TranscriptSearch.swift`,
  `BackgroundTasks.swift` / `BackgroundTaskStore.swift` / `BackgroundTaskPane.swift`.
- **Repo root**: `scripts/claude/` (statusline + hook scripts, bundled by `build.sh`),
  `scripts/*.sh` test harnesses, `design/` (reference render), `Resources/Info.plist`
  (bundle id `dev.kosych.suit`; add `NS*UsageDescription` keys here when a feature needs one),
  `build.sh`.
- **Vendored deps**: `swift/Vendor/SwiftTerm/` — vendored SwiftTerm source (the pty terminal
  view).

For any file's full behavior, read its header region and the tests that cover it — the code is
the source of truth for details.

## Conventions

- Match the surrounding code — this repo favors dense, descriptive doc-comments
  at the top of each file explaining the *why*; keep that up when you add files.
- Adding a new pane kind = implement `PaneContent`; the split tree, focus, and
  drag-rearrange all work unchanged.
- Pure, testable logic goes in a Foundation-only file with no app deps (the
  `RoadmapParser`/`AutopilotScheduler`/`FeedbackRouting` pattern) so a harness
  can compile it standalone.
- Privacy invariants are load-bearing: SSH passwords live only in the Keychain,
  never in JSON/logs/saved state; OSC 52 clipboard reads are denied. Don't
  regress these.

## Agent tooling

- `CLAUDE.md` — a stub that points here (Claude Code auto-loads it). Keep it a pointer;
  all agent guidance lives in this file.
- `.claude/commands/` — repo slash commands: `/build`, `/test`,
  `/render-reference`, `/orient`, `/find-file`.
- `.claude/settings.json` — shared permission allowlist for safe repeated commands. It
  deliberately does not auto-allow `git push` (asks) or force-push (denied).
  `.claude/worktrees/` stays git-ignored.

## Workflow

- **Always work on a new branch in its own git worktree** (`EnterWorktree`) — never directly in
  the main checkout. Concurrent sessions have clobbered each other here before. Exit with
  `keep` to persist, `remove` once merged/abandoned.
  - **Worktree FIRST, always** — the very first action for *any* task, including a "trivial"
    one-liner or "just merge this branch", is to create the worktree. Never run merges, edits,
    builds, or `git checkout`/`git add`/`git commit` in the shared main checkout: other live
    sessions switch branches and commit under you mid-operation and will silently wipe your
    in-progress merge or index. This has happened repeatedly.
  - **To land on `main`**, do the work in a worktree whose branch *is* `main`
    (`git worktree add <path> main`) so the merge commit advances `main` without touching the
    shared checkout — which also stops a concurrent session from grabbing `main` while you work.
    If you ever catch yourself dirtying the shared checkout, back up the diff, restore it clean,
    and restart in a worktree.
- **After implementing a feature, document it in `docs/features.md`** (user-facing behavior,
  shortcuts, settings) as part of the same task — that's the full feature reference. Keep
  `README.md` lean: it carries only the Highlights summary and a pointer into `docs/features.md`,
  so touch the README only when a change belongs in Highlights or the shortcuts table.
- **`/goal` tasks follow the full loop** without asking: worktree → implement → `gh pr create`
  against `main` → `gh pr merge`, resolving any conflicts (rebase on `main`, re-push) until
  merged. Stop only when merged or genuinely blocked.

## Permissions / entitlements

The bundle is ad-hoc code signed in `build.sh`, so TCC tracks grants against `dev.kosych.suit`
rather than Terminal.app. A rebuilt bundle re-prompts for the first Keychain read — expected.
When a feature needs a new permission, add the required `Info.plist` usage-description key.
