# CLAUDE.md

Rules for Claude Code (claude.ai/code) in this repository. This document uses ASD-STE100,
Simplified Technical English.

Suit (**S**top **U**sing **I**DE **T**erminal) is a personal macOS app. It is a native AppKit
bundle. Each window contains a split tree of panes. Each pane shows tabs in the style of a web
browser: terminals (`/bin/zsh -l -i` on the pty of SwiftTerm), file viewers, diffs, transcripts
and dashboards. The app is one module of 192 Swift files. It uses only AppKit, the SwiftTerm
source in this repository, and the Hack font in the bundle.

`README.md` introduces the app. `docs/features.md` gives the behavior of each function.
`docs/development.md` gives the setup steps for a person. This file gives you two things that the
code does not show: the rules, and the errors that caused problems in other sessions.

---

## 1. Always work in a worktree

Other Claude Code sessions change this repository now. These sessions change branches. They stage
files. They make commits. They do not tell you. If two sessions use one working tree, each session
overwrites the changes of the other session. The result is a diff with incorrect content.

```sh
git worktree add -b feature/tab-drag .claude/worktrees/tab-drag main
```

- **Make the worktree before your first change.** This rule applies also to a correction of one
  line, and to a correction of one word in a document. Give the worktree the name of the task. If
  two agents use the name `wip`, a conflict occurs. Git ignores `.claude/worktrees/`.
- **Read-only work does not need a worktree.** Stay where you are if you only answer a question
  from the code, run `rg`, or read a diff.
- **Do not write in the shared checkout at `~/Projects/suit`.** Do not make changes there. Do not
  make commits or builds there. If you change it by accident, keep a copy of the diff. Then make
  the checkout clean. Then start again in a worktree.
- **Ask which branch receives the work before you write the code.** Do not ask after. Do not
  assume that the branch is `main`. To move completed work to a different branch is expensive. To
  ask one question is not expensive.
- Remove the worktree after the work is in the branch (`git worktree remove <path>`).

A worktree keeps the repository separate. It does not keep all data separate. Each agent that
operates shares all data at a constant path outside the worktree:

| Path | Is it shared? | Rule |
| --- | --- | --- |
| `build/`, `scripts/test.sh` | No. Each worktree has its own. The harnesses put `$HOME` in a sandbox. | Safe. |
| `/tmp/suit-shell` | **Yes** | Give each quick `swiftc` build the name of its task: `/tmp/suit-shell-$TASK`. |
| `/tmp/suit-design-reference` | **Yes.** The path is in `design/render-reference.sh`. | Do not run the script if a different session can make a render at the same time. |
| `~/.suit/` | **Yes.** This is the live data of the app. | The harnesses put `$HOME` in a sandbox. Your own scripts must do the same. |

## 2. Git: `main` has protection

- **Do not push to `main`. Do not force-push. Do not do a hard reset.** GitHub refuses a direct
  push (`Changes must be made through a pull request`). Thus, to put work on the remote, use
  `git push -u origin <branch>`. Then make a pull request against `main`.
- To get the work of other persons, merge `main` into your branch. To put your work in the local
  repository, merge your task branch into the local `main`. Do this only if the user asks for it.
- `git worktree add <path> main` fails if the shared checkout has `main`. Git refuses one branch in
  two worktrees. Make a new branch, which is also the correct procedure.
- Do not add a `Co-Authored-By: Claude` trailer. Do not add a "Generated with Claude Code" line.
- `.claude/settings.json` contains the shared list of permitted commands. It does not permit
  `git push` automatically, thus the command asks first. It refuses a force-push.

## 3. Build and test

```sh
./build.sh                      # compiles swift/, assembles + ad-hoc signs build/Suit.app
open build/Suit.app
```

To do a quick loop without a bundle:

```sh
swiftc -O -j $(sysctl -n hw.ncpu) swift/Sources/suit/*.swift \
  $(find swift/Vendor/SwiftTerm -name '*.swift') -o /tmp/suit-shell-$TASK && /tmp/suit-shell-$TASK
```

**Always use the `-j` option.** `swiftc` makes one frontend job for each file. There are 273 files:
212 sources and 61 files from SwiftTerm. By default, `swiftc` runs these jobs in sequence. This
takes about 3 minutes on one core, while ten cores do no work. The `-j` option decreases
the time to about 30 seconds. It changes only the schedule of the jobs. Use `-Onone`
(about 16 seconds) if you only need a binary that runs. Do not use `-Onone` to examine the
smoothness of a scroll, or the performance.

**There is no SwiftPM and no Xcode project.** This computer has a beta version of the Xcode Command
Line Tools. With this version, `swift build` cannot link an empty manifest. `swiftc` alone does not
have this problem. Thus the source of SwiftTerm is in this repository
(`swift/Vendor/SwiftTerm/`), and all the code compiles as one module. Do not run
`xcode-select --install`. Do not make an `.xcodeproj`. Do not use SwiftPM again before you ask.
Put each new Swift dependency in the repository in the same way.

```sh
scripts/test.sh                 # 29 fast harnesses, ~seconds
scripts/test.sh --all           # + the slow source-control gate (~40 s)
scripts/test.sh --list          # names, scripts, speed
scripts/editor-ops-test.sh      # one harness directly — the inner loop
```

There is no XCTest target. **Standalone harnesses** test the logic that has no user interface.
Each harness has two parts:

- `scripts/<name>-test.sh` compiles the related files with a driver. Then it runs the driver with a
  `$HOME` in a sandbox.
- `scripts/<name>-test/main.swift` contains the assertions. It prints `ok:` or `FAIL:`.

New logic must have the same shape. Write a core that uses only Foundation and has no dependency on
the app. Then write a thin AppKit part that connects the core to the app (`FeedbackRouting`,
`EditorOps`, `ThemeStore`). Then add a harness. Then add the harness to `HARNESSES` in
`scripts/test.sh`. `.github/workflows/swift.yml` runs `./build.sh` and `scripts/test.sh` for each
pull request to `main`. Thus a harness with an error, or a harness that you did not add to the
list, stops the merge.

**A change to the chrome has no harness.** A reference render in the repository protects it. Run
`design/render-reference.sh` again and commit `design/phase15-window.png`. The render shows a clock
with the current time, thus the bytes of the file are different after each run. Make a new render
only after a true change to the chrome. Compare the two images with your eyes, and not by the size
of the diff. Expect a conflict if a different session changed the same file.

**Look at a visual change with your eyes.** `design/reference/main.swift` shows how to operate the
app offscreen. It makes an `AppDelegate`, opens a window, runs the run loop, and writes a view to a
PNG file with `cacheDisplay`. Copy this file into your scratchpad. Use your own output paths and a
`$HOME` in a sandbox. Then look at the result. A screenshot shows the errors that the compiler
cannot find: a black terminal with a light theme, or a control that the app did not draw.

## 4. Architecture — the most important ideas

- **A tab is the unit. A pane is a viewport.** (`TabStore.swift`, `Pane.swift`,
  `PaneTabBarView.swift`.) A window has one list of tabs in sequence. It also has an order of the
  most recent use. Each pane shows a maximum of one tab. A tab in the background keeps its process
  alive. A split starts with a tab (⌘D, a click with the right button, or a drag of a tab to the
  edge of a pane). A file is a usual tab. The app opens only one tab for each path.
- **`PaneContent`** (`PaneContent.swift`) is what a pane can contain: the view, the focus target,
  the title, the hooks for the appearance (`applyFont` / `applyTextColor` / `applyBackground` /
  `reapplyTheme`), and the teardown. If you implement it, the splits, the title bars, the focus and
  the drag continue to operate without a change.
- **The app calculates the focus. It does not set the focus.** (`Pane.swift`,
  `PaneContainerView.swift`.) The window controller monitors `window.firstResponder` with KVO.
  Then it draws each pane again from that value, at one location. New data about the focus must
  read from that location. It must not operate in parallel with it.
- **The theme is a system of tokens** (`Theme.swift`, `Theme+Palettes.swift`, `ThemeStore.swift`).
  A component must not contain a hexadecimal color or an unexplained value for the padding. Each
  color is a `Theme.*` token that reads the active `Palette`. Each metric and each font stays a
  `static let`. `Palette.colorTokens` declares the 26 tokens one time. That declaration controls
  Codable and also the editor in the Settings window, thus you add a token with one change. A color
  becomes `#RRGGBB` in the file, or `#RRGGBBAA` if the token is translucent. A change of the theme
  sends `Theme.didChange` with the **previous** palette. With that palette, an observer can find
  the difference between "this surface obeyed the theme" and "the user selected this color".
  **A value that you keep from a token at initialization is an error.** Read each token when you
  draw, or read it again in `reapplyTheme`.
- **`~/.suit/` is the directory for the data** (favorites, notes, recipes, layouts, sessions, tasks,
  markers, ssh hosts and themes). Each store obeys the pattern of `FavoritesStore`. It finds
  `$HOME` through `ProcessInfo`, thus a harness can put it in a sandbox. It writes atomically with
  `StoreFile.swift`. It sends a `didUpdate` notification. A decoder must accept a key that is
  absent, and a key that it does not know. Thus a file from an older or a newer Suit continues to
  load.
- **Claude integration** (`ClaudeSessions.swift`, `ClaudeIntegration.swift`, `scripts/claude/`).
  The statusline script and the hook scripts write JSON about the session and the usage in
  `~/.suit/`. The app monitors those files. It maps each session to a pane. It answers into the pty
  with `SessionControl.send` (a bracketed paste, then `\r` after a delay). Install the scripts with
  the installer in the app. Do not install them manually.
- **The app keeps and restores the state** (`StateRestoration.swift`). At quit, it makes a record of
  the tabs, the split tree and the scroll positions of the viewers in each window. At launch, it
  puts them back. `Layouts.swift` uses the same machinery for a workspace with a name. A new
  `PaneContent` with a state must write that state into the record.

## 5. Where the files are

All the files are in `swift/Sources/suit/`. The directory is flat and has no subdirectory. The name
of a file tells you what the file does. Thus `rg` finds a subsystem more quickly than a map of the
files. Each file starts with a large comment that gives the reasons for its design, and that
comment is the true reference. A subsystem with more than one file has the shape `Foo.swift` plus
`Foo+Aspect.swift` (`AppDelegate+*`, `TerminalWindowController+*`, `FileViewerPane+*`,
`DiffPane+*`, `GitView+*`). Start at the base file.

| Area | Entry points |
| --- | --- |
| App shell | `main.swift`, `AppDelegate.swift`, `TerminalWindowController.swift`, `CommandPalette.swift`, `SettingsWindowController.swift` |
| Tabs and panes | `TabStore.swift`, `Pane.swift`, `PaneContent.swift`, `PaneTabBarView.swift`, `StateRestoration.swift` |
| Theme | `Theme.swift` (the tokens), `Theme+Palettes.swift` (the 14 themes in the app), `ThemeStore.swift` (the catalog and the `.suittheme` files) |
| Sidebar | `ActivityBarView.swift` (the strip of icons; `WindowRootView` puts it *outside* the sidebar split, thus it stays after ⌘B), `SidebarView.swift`, `FileBrowserView.swift`, `SearchView.swift` plus `SearchReplace.swift` (the find and replace functions of the Search tab), `RipgrepSearch.swift` |
| Viewer and editor | `FileViewerPane.swift`, `EditorOps.swift`, `FindReplace.swift`, `CodeFolding.swift`, `SymbolIndex.swift`, `SyntaxHighlighter.swift` plus `SyntaxLanguages.swift`, `MarkdownPane.swift` |
| Git and GitHub | `GitStatus.swift`, `GitView.swift` (the Source Control tab) plus `GitView+Commit.swift` (the stage function, the message box, the menu of actions), `GitBranchOps.swift` (the argv for each git action, without a user interface), `DiffPane.swift`, `DiffParser.swift`, `GitBranches.swift` (the wrapper for gh; it continues to operate without gh), `CommitGraph.swift`, `WorktreeTasks.swift` |
| Claude | `ClaudeSessions.swift`, `ClaudeIntegration.swift`, `TranscriptPane.swift`, `Recipes.swift`, `Dictation.swift`, `GoalComposition.swift` |
| Fleet | `FleetDashboard.swift`, `FleetModel.swift`, `Activity.swift`, `BudgetGuardrails.swift` |
| Root of the repository | `build.sh`, `scripts/claude/` (the hooks in the bundle), `scripts/*.sh` (the harnesses), `design/`, `Resources/Info.plist` (the bundle identifier `dev.kosych.suit`) |

## 6. Conventions

- **Write code in the style of the code around it.** This includes the large header comments that
  give the reasons. A comment here tells why a person made a decision. It does not tell what the
  next line does.
- To make a new type of pane, implement `PaneContent`. Then the splits, the focus and the drag
  operate immediately.
- Put logic that is pure and testable in a file that uses only Foundation and has no dependency on
  the app. Then a harness can compile that file alone.
- **The rules for privacy are very important.** An SSH password stays only in the Keychain. It must
  never go into JSON, into a log, or into the data that the app keeps. The app refuses an OSC 52
  *read* of the clipboard. Do not make these rules weaker.
- `build.sh` signs the bundle with an ad-hoc signature. Thus TCC records the permissions against
  `dev.kosych.suit`. After a new build of the bundle, the first read of the Keychain asks the user
  again. This is correct behavior and not an error.
- **Write about a completed function in `docs/features.md`** (the behavior, the shortcuts and the
  settings) in the same task. Keep `README.md` short: the Highlights, the pointers to other
  documents, and the table of shortcuts.
- A prompt that starts with **`/goal`** comes from the "Set as Goal" command of the app.
  `GoalComposition.swift` writes it into the pty of a session. It is not a file in
  `.claude/commands/`. For such a prompt, do the full procedure and do not ask: make a worktree,
  write the code, run `gh pr create` against `main`, then run `gh pr merge`. Correct each conflict
  until the merge is complete. Stop only after the merge, or if you cannot continue.

## 7. Get a second opinion before an important decision

Ask a different model. It makes different errors than you, and that is the reason to ask it. Use
the Agent tool with `subagent_type: general-purpose`, `model: fable` and
`run_in_background: false`. Start with these words: *"You are the Suit advisor: an adversarial
reviewer whose job is to refute, not agree. Re-check every claim against the repo rather than
taking my word."*

**Ask before you act.** These actions are permanent, thus an examination after the action is too
late:

- a git command that can destroy work that you did not write;
- a change to a rule in this file, or a method to avoid a rule in this file (if you write the
  reasons for such a change, you must ask);
- a change to the build tools or to the dependencies;
- a change to the format of the data in `~/.suit/`.

**Ask after you write the code and before the merge** if the diff touches `PaneContent`,
`TabStore`, the calculation of the focus, or the restoration of the state. Ask also if the diff is
more than about 300 lines. You do not need to ask for mechanical work, or for a new
function that obeys a pattern that exists. But these two conditions are stronger than that
permission: if the diff has that size, or if it touches those files, you must ask.

Give the model the exact diff, or the exact commands. Do not give it your description of them.
Give a number to each fact, with the SHAs and the absolute paths. Tell the model where you think
your own errors are. Give it the absolute path of your worktree. Ask the model to **refute this**.
Do not ask "what do you think?", because a neutral question gets agreement with a good summary.
The answers become old quickly: other sessions make commits during the consultation, thus examine
the repository again before a permanent action. **If the model says that you must not continue,
tell the user about the disagreement and stop.** If two models disagree, the user decides.

If this session has no subagents, tell the user. Do not go past this step without a word, and let
the user decide.
