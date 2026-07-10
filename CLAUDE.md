# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## What this is

Suit (**S**top **U**sing **I**DE **T**erminal) is a personal macOS app growing from a terminal
into a Claude-code-first cockpit for codebase work (see `ROADMAP.md` for the phased plan). It's a
native AppKit app bundle whose windows host split trees of panes displaying browser-style tabs —
terminals (interactive `/bin/zsh -l -i` on SwiftTerm's pty), file viewers, diffs, and other
`PaneContent` implementations. Swift/AppKit is the product/UI layer; heavy non-UI logic may move
to a Go sidecar if it outgrows Swift.

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

- **App shell**: `main.swift`, `AppDelegate.swift` (windows, menu bar, palette command
  registry, settings persistence, global shortcuts), `SettingsWindowController.swift`,
  `CommandPalette.swift` (⌘K palette, also ⌘P file picker), `OverlayPrompt.swift`.
- **Tabs & panes**: `TabStore.swift`, `TabStripView.swift`, `TabSwitcherPanel.swift` (⌃Tab MRU),
  `Pane.swift`, `PaneContent.swift`, `StateRestoration.swift`, `Layouts.swift` +
  `AppDelegate+Layouts.swift`, `PaneScreensaverView.swift`, `ProcessUtil.swift`.
- **Sidebar**: `SidebarView.swift` (icon rail: Files / Bookmarks / SSH Hosts / Notes),
  `FileBrowserView.swift` (tree + `GitFooterView` branch/worktree switcher),
  `SearchView.swift` (⇧⌘F), `FileIndex.swift` (git-aware file list behind ⌘P and the browser),
  `RipgrepSearch.swift` (bundled `rg --json`), `Favorites.swift` (recent project roots),
  `Notes.swift`, `SSHHosts.swift` / `SSHPane.swift` / `SSHHostsView.swift`.
- **Viewer & editing**: `FileViewerPane.swift` (+ `Editing`, `Symbols`, `TimeTravel` extensions),
  `FileEdit.swift`, `FileTimeTravel.swift`, `SyntaxHighlighter.swift`, `MinimapView.swift`,
  `SymbolIndexCore.swift` / `SymbolIndex.swift` (ctags go-to-definition),
  `ReferencesPane.swift`.
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
  `ActivityFeedController.swift`.
- **Autopilot**: `AutopilotEngine.swift`, `AutopilotScheduler.swift`, `RoadmapParser.swift`,
  `AutopilotStore.swift`, `AutopilotGates.swift`, `AutopilotPrompts.swift`.
- **Repo root**: `scripts/claude/` (statusline + hook scripts, bundled by `build.sh`),
  `scripts/*.sh` test harnesses, `design/` (reference render), `Resources/Info.plist`
  (bundle id `dev.kosych.suit`; add `NS*UsageDescription` keys here when a feature needs one),
  `build.sh`.

For any file's full behavior, read its header region and the tests that cover it — the code is
the source of truth for details.

## Agent tooling

- `AGENTS.md` — the 60-second orientation; keep it in sync with this file when build/test
  commands or load-bearing rules change.
- `.claude/commands/` — repo slash commands: `/build`, `/test`, `/claim-phase`,
  `/render-reference`, `/orient`, `/find-file`.
- `.claude/settings.json` — shared permission allowlist for safe repeated commands. It
  deliberately does not auto-allow `git push` (asks) or force-push (denied).
  `.claude/worktrees/` stays git-ignored.

## Workflow

- **Always work on a new branch in its own git worktree** (`EnterWorktree`) — never directly in
  the main checkout. Concurrent sessions have clobbered each other here before. Exit with
  `keep` to persist, `remove` once merged/abandoned.
- **Claim a ROADMAP.md phase before starting it**: append ` 🚧 in progress (<branch>, <date>)`
  to the phase heading and commit that one line to main *before* creating the worktree. Pick
  the first phase in document order not marked `🚧` / `✅` / `⏸`. Replace `🚧` with `✅` when it
  ships (or remove it if abandoned).
- **After implementing a phase, document it in `README.md`** (user-facing behavior, shortcuts,
  settings) as part of the same task.
- **`/goal` tasks follow the full loop** without asking: worktree → implement → `gh pr create`
  against `main` → `gh pr merge`, resolving any conflicts (rebase on `main`, re-push) until
  merged. Stop only when merged or genuinely blocked.

## Permissions / entitlements

The bundle is ad-hoc code signed in `build.sh`, so TCC tracks grants against `dev.kosych.suit`
rather than Terminal.app. A rebuilt bundle re-prompts for the first Keychain read — expected.
When a feature needs a new permission, add the required `Info.plist` usage-description key.
