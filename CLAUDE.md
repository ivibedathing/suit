# CLAUDE.md

Guidance for Claude Code (claude.ai/code) working in this repository.

Suit (**S**top **U**sing **I**DE **T**erminal) is a personal macOS app: a native AppKit bundle
whose windows host split trees of panes showing browser-style tabs — terminals (`/bin/zsh -l -i`
on SwiftTerm's pty), file viewers, diffs, transcripts, dashboards. One module, 192 Swift files,
nothing beyond AppKit, vendored SwiftTerm, and the bundled Hack font.

`README.md` is the pitch, `docs/features.md` the shipped-behavior reference, `docs/development.md`
the human setup guide. This file is for you: the rules that aren't discoverable from the code, and
the traps that have actually cost sessions.

---

## 1. Work in a worktree. Always.

Other Claude Code sessions are editing this repo *right now*. They switch branches, stage files,
and commit under you without warning. Two sessions in one working tree overwrite each other and
produce half-merged diffs.

```sh
git worktree add -b feature/tab-drag .claude/worktrees/tab-drag main
```

- **Create it before your first edit** — a one-line fix and a doc typo included. Name it after the
  task; two agents that both pick `wip` collide. `.claude/worktrees/` is git-ignored.
- **Read-only exploration doesn't need one.** Answering a question from the code, running `rg`,
  reading a diff — stay where you are.
- **Never write in the shared checkout at `~/Projects/suit`** — no edits, commits, or builds. If
  you dirty it, back up the diff, restore it clean, and restart inside a worktree.
- **Ask which branch the work merges into before implementing**, not after. Never assume `main`.
  Moving finished work onto a different base is expensive; asking costs one question.
- Remove the worktree once the work has landed (`git worktree remove <path>`).

A worktree isolates the repo, not everything a build touches. Anything at a fixed path outside it
is shared with every running agent:

| Path | Shared? | Rule |
| --- | --- | --- |
| `build/`, `scripts/test.sh` | no — per worktree, `$HOME`-sandboxed | safe |
| `/tmp/suit-shell` | **yes** | give quick `swiftc` builds a task-specific name: `/tmp/suit-shell-$TASK` |
| `/tmp/suit-design-reference` | **yes**, hardcoded in `design/render-reference.sh` | don't run it while another session might be rendering |
| `~/.suit/` | **yes** — the running app's live state | harnesses sandbox `$HOME`; ad-hoc scripts you write must too |

## 2. Git: `main` is protected

- **Don't push, force-push, or hard-reset `main`.** GitHub rejects a direct push anyway
  (`Changes must be made through a pull request`), so landing on the remote means
  `git push -u origin <branch>` plus a PR against `main`.
- To integrate other people's work, merge `main` **into** your branch. To land locally, merge your
  task branch **into** local `main` — but only when the user asked for that.
- `git worktree add <path> main` fails when the shared checkout is already on `main` (git refuses
  one branch in two worktrees). Branch instead — which you were going to do anyway.
- Never add `Co-Authored-By: Claude` trailers or "Generated with Claude Code" lines.
- `.claude/settings.json` is a shared permission allowlist. It deliberately does not auto-allow
  `git push` (asks) and denies force-push.

## 3. Build & test

```sh
./build.sh                      # compiles swift/, assembles + ad-hoc signs build/Suit.app
open build/Suit.app
```

Iterating without assembling a bundle:

```sh
swiftc -O -j $(sysctl -n hw.ncpu) swift/Sources/suit/*.swift \
  $(find swift/Vendor/SwiftTerm -name '*.swift') -o /tmp/suit-shell-$TASK && /tmp/suit-shell-$TASK
```

**Always pass `-j`.** `swiftc` plans one frontend job per file (273 — 212 sources plus 61 vendored)
and runs them *serially* by default: ~3 minutes on one core with ten idle. `-j` drops it to ~30 s
and changes nothing but scheduling. Add `-Onone` (~16 s) when you only need a binary that runs —
it's the wrong build for judging scroll smoothness or anything perf-shaped.

**No SwiftPM, no Xcode project.** This machine runs a beta Xcode CLT where `swift build` fails to
link even an empty manifest; plain `swiftc` is unaffected. So SwiftTerm is vendored as source
(`swift/Vendor/SwiftTerm/`) and everything compiles as one module. Don't run
`xcode-select --install`, create an `.xcodeproj`, or reintroduce SwiftPM without checking first.
Vendor new Swift dependencies the same way.

```sh
scripts/test.sh                 # 29 fast harnesses, ~seconds
scripts/test.sh --all           # + the slow source-control gate (~40 s)
scripts/test.sh --list          # names, scripts, speed
scripts/editor-ops-test.sh      # one harness directly — the inner loop
```

There is no XCTest target. UI-free logic is verified by **standalone harnesses**: a pair of
`scripts/<name>-test.sh` (compiles the relevant file(s) against a driver and runs it under a
scratch `$HOME`) and `scripts/<name>-test/main.swift` (the assertions, printing `ok:` / `FAIL:`).
New logic follows the same shape — a Foundation-only core with no app dependencies, plus a thin
AppKit half wiring it in (`FeedbackRouting`, `EditorOps`, `ThemeStore`) — adds a
harness, and registers it in `HARNESSES` in `scripts/test.sh`. `.github/workflows/swift.yml` runs
`./build.sh` and `scripts/test.sh` on every PR to `main`, so an unwired or broken harness blocks
the merge.

**Chrome changes have no harness.** They're guarded by a committed reference render: re-run
`design/render-reference.sh` and commit `design/phase15-window.png`. The render draws a live clock,
so its bytes differ every run — only re-render on a real chrome change, compare visually rather
than by diff size, and expect conflicts if another session touched it.

**Verify visually when the change is visual.** `design/reference/main.swift` is a working pattern
for driving the app offscreen: construct `AppDelegate`, open a window, pump the run loop,
`cacheDisplay` a view into a PNG. Copy it into your scratchpad with your own output paths and a
sandboxed `$HOME`, then *look at the result*. Screenshots catch what compiles fine — a black
terminal under a light theme, a control that never drew.

## 4. Architecture — the load-bearing ideas

- **Tabs are the unit; panes are viewports** (`TabStore.swift`, `Pane.swift`,
  `PaneTabBarView.swift`). A window owns one ordered tab list plus an MRU order. Each pane displays
  at most one tab, and a backgrounded tab keeps its process running. Splitting is tab-first (⌘D,
  right-click, drag a tab to a pane edge); files are ordinary tabs, deduped by path.
- **`PaneContent`** (`PaneContent.swift`) is what a pane can host: view, focus target, title,
  appearance hooks (`applyFont` / `applyTextColor` / `applyBackground` / `reapplyTheme`), teardown.
  Implement it and splits, title bars, focus, and drag work unchanged.
- **Focus is derived, never pushed** (`Pane.swift`, `PaneContainerView.swift`). The window
  controller KVO-observes `window.firstResponder` and repaints every pane from it in one place.
  Any "who is focused" state you add should read from there rather than run alongside it.
- **Theming is a token system** (`Theme.swift`, `Theme+Palettes.swift`, `ThemeStore.swift`). No
  component states a hex or a magic padding — every color is a `Theme.*` token reading the active
  `Palette`, while metrics and fonts stay `static let`. The 26 tokens are declared once in
  `Palette.colorTokens`, which drives Codable *and* the Settings editor, so adding one is a single
  edit. Colors serialize as `#RRGGBB`, or `#RRGGBBAA` where a token is translucent. A theme switch
  posts `Theme.didChange` carrying the **outgoing** palette, which is how observers tell "this
  surface was following the theme" from "the user picked this color". **Anything you cache from a
  token at init is a bug** — read tokens at draw time, or re-read them in `reapplyTheme`.
- **`~/.suit/` is the state directory** (favorites, notes, recipes, layouts, sessions, tasks,
  markers, ssh hosts, themes). Stores follow the `FavoritesStore` pattern: `$HOME`
  resolved through `ProcessInfo` so harnesses can sandbox it, atomic writes via `StoreFile.swift`,
  a `didUpdate` notification. Decoders tolerate missing and unknown keys — a state file written by
  an older or newer Suit must still load.
- **Claude integration** (`ClaudeSessions.swift`, `ClaudeIntegration.swift`, `scripts/claude/`):
  statusline and hook scripts write session/usage JSON under `~/.suit/`; the app watches those
  files, maps sessions to panes, and talks back into the pty via `SessionControl.send` (bracketed
  paste, delayed `\r`). Scripts install through the in-app installer, never by hand.
- **State restoration** (`StateRestoration.swift`) snapshots each window's tabs, split tree, and
  viewer scrolls at quit and replays them at launch; `Layouts.swift` reuses the machinery for named
  workspaces. A new `PaneContent` that carries state should encode into that snapshot.

## 5. Where things live

Everything is in `swift/Sources/suit/`, flat, no subdirectories. Files are named after what they
do, so `rg` finds a subsystem faster than any map — and each file opens with a dense doc comment
explaining the *why*, which is the real reference. A multi-file subsystem splits as `Foo.swift` +
`Foo+Aspect.swift` (`AppDelegate+*`, `TerminalWindowController+*`, `FileViewerPane+*`,
`DiffPane+*`, `GitView+*`); start at the base file.

| Area | Entry points |
| --- | --- |
| App shell | `main.swift`, `AppDelegate.swift`, `TerminalWindowController.swift`, `CommandPalette.swift`, `SettingsWindowController.swift` |
| Tabs & panes | `TabStore.swift`, `Pane.swift`, `PaneContent.swift`, `PaneTabBarView.swift`, `StateRestoration.swift` |
| Theme | `Theme.swift` (tokens), `Theme+Palettes.swift` (the 14 built-ins), `ThemeStore.swift` (catalog, `.suittheme` files) |
| Sidebar | `ActivityBarView.swift` (icon strip, laid out by `WindowRootView` *outside* the sidebar split so it survives ⌘B), `SidebarView.swift`, `FileBrowserView.swift`, `SearchView.swift` + `SearchReplace.swift` (the Search tab's find/replace), `RipgrepSearch.swift` |
| Viewer & editing | `FileViewerPane.swift`, `EditorOps.swift`, `FindReplace.swift`, `CodeFolding.swift`, `SymbolIndex.swift`, `SyntaxHighlighter.swift` + `SyntaxLanguages.swift`, `MarkdownPane.swift` |
| Git & GitHub | `GitStatus.swift`, `GitView.swift` (the Source Control tab) + `GitView+Commit.swift` (staging, commit box, actions menu), `GitBranchOps.swift` (the UI-free argv for every git action), `DiffPane.swift`, `DiffParser.swift`, `GitBranches.swift` (gh wrapper, degrades without gh), `CommitGraph.swift`, `WorktreeTasks.swift` |
| Claude | `ClaudeSessions.swift`, `ClaudeIntegration.swift`, `TranscriptPane.swift`, `Recipes.swift`, `Dictation.swift`, `GoalComposition.swift` |
| Fleet | `FleetDashboard.swift`, `FleetModel.swift`, `Activity.swift`, `BudgetGuardrails.swift` |
| Repo root | `build.sh`, `scripts/claude/` (bundled hooks), `scripts/*.sh` (harnesses), `design/`, `Resources/Info.plist` (bundle id `dev.kosych.suit`) |

## 6. Conventions

- **Match the surrounding code**, including the dense why-focused header comments. A comment here
  explains why a decision was made, not what the next line does.
- A new pane kind = implement `PaneContent`. Splits, focus, and drag follow for free.
- Pure, testable logic goes in a Foundation-only file with no app dependencies, so a harness can
  compile it standalone.
- **Privacy invariants are load-bearing**: SSH passwords live only in the Keychain, never in
  JSON/logs/saved state; OSC 52 clipboard *reads* are denied. Don't regress these.
- The bundle is ad-hoc signed in `build.sh`, so TCC tracks grants against `dev.kosych.suit`. A
  rebuilt bundle re-prompts for the first Keychain read — expected, not a bug.
- **Document a shipped feature in `docs/features.md`** (behavior, shortcuts, settings) in the same
  task. Keep `README.md` lean — Highlights, pointers, and the shortcuts table.
- A prompt starting with **`/goal`** arrives from the app's "Set as Goal" gesture
  (`GoalComposition.swift` types it into a session's pty — it is not a `.claude/commands/` file).
  Those run the full loop without asking: worktree → implement → `gh pr create` against `main` →
  `gh pr merge`, resolving conflicts until merged. Stop only when merged or genuinely blocked.

## 7. Get a second opinion at decision gates

Consult a different model — it fails differently than you do, which is the point. Agent tool,
`subagent_type: general-purpose`, `model: fable`, `run_in_background: false`. Open with *"You are
the Suit advisor: an adversarial reviewer whose job is to refute, not agree. Re-check every claim
against the repo rather than taking my word."*

**Before acting** (these are irreversible, so afterwards is an autopsy): destructive git that could
lose work you didn't create; changing or working around a rule in this file (writing the
justification *is* the trigger); build-tooling or dependency changes; format changes to persisted
`~/.suit/` state.

**After implementing, before merge**: any diff touching `PaneContent`, `TabStore`, focus
derivation, or state restoration — or any diff past ~300 lines. Skip it for mechanical work and
additive features that follow an existing pattern, but the skip list never overrides a fired gate:
the line count and the file list win.

Give it the exact diff or commands (not your description), every factual claim numbered with SHAs
and absolute paths, your best guess at your own blind spot, and your worktree's absolute path. The
ask is **refute this**, not "what do you think?" — a neutral ask buys agreement with a well-written
summary. Findings expire: other sessions commit during a consult, so re-verify before doing
anything irreversible. **If it says don't proceed, surface the disagreement and stop** — two models
disagreeing is the user's call.

If the session is configured without subagents, say so instead of skipping the gate silently, and
let the user decide.
