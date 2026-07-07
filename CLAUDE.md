# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Suit (**S**top **U**sing **I**DE **T**erminal) is a personal macOS app growing from a terminal into a Claude-code-first cockpit for
monorepo work (see `ROADMAP.md` for the phased plan). Today it's a native app bundle (Dock icon,
own bundle identifier, own TCC permission entries) whose windows host split trees of terminal
panes, each running an interactive shell (`/bin/zsh -l -i`) directly via SwiftTerm's pty (see
`PaneContent.swift`). Swift/AppKit is the product/UI layer; heavy non-UI logic (indexing,
monorepo analysis) may live in a Go sidecar if it outgrows Swift.

- `swift/Sources/suit/` — the AppKit app. This is the product layer (per `ROADMAP.md`), no
  longer a "keep it minimal" shell; UI features live here.
  - `main.swift` — creates the `NSApplication` and runs it.
  - `AppDelegate.swift` — app-level state and dispatch: the list of `TerminalWindowController`s
    (windows; native macOS window tabbing is disabled — the in-window strip is the one tab
    system), the menu bar, the command palette's command registry (`paletteCommands()`),
    and global appearance/terminal defaults (font, text color, default pane background, opacity,
    blur, shell path, cursor style, bell responses — see
    `SettingsWindowController.swift`), persisted to `UserDefaults` along with the last-focused
    pane's cwd and a full layout snapshot at quit time (see `StateRestoration.swift` — the next
    launch reopens every window's tab list, split tree, and viewer scroll positions; the cwd
    stays as the fallback for a fresh start). Tab/screen actions (⌘T new tab, ⌘W close tab,
    ⇧⌘T reopen, ⌘1..9 go to tab N with ⌘9 = last, ⌃Tab MRU switcher, ⌘D split screen with
    a fresh terminal tab (focused pane's cwd), ⌥⌘W unsplit,
    ⌥⌘arrows focus split, ⌃⌘M unsplit all, …) route to whichever window
    controller is key. Splitting is tab-first (Phase 13): strip right-click ▸ Split
    Screen / Unsplit, ⌘D, the Screen menu's / palette's last-used-tab and
    "Split Screen with Tab…" picker entries, or drag a tab to a
    screen edge — no pane-first split commands. Single-field prompts (rename tab, new Claude
    task) use `OverlayPrompt.swift`, the palette-style panel (Phase 15), not NSAlert. Also the cross-window
    tab plumbing: `controllerAndTab(withId:)` resolves a dragged tab across windows, and
    `tearOffTab(withId:at:)` turns a tab dragged outside every window into its own window.
  - `TabStore.swift` — the browser-tab model (the tabs rebuild): `Tab` wraps any `PaneContent`
    plus its strip state (id, kind → SF Symbol icon, content/custom title, exit status,
    preview/pinned flags, Claude session) and receives the content callbacks
    (`contentTitleDidChange`/`contentProcessDidExit`) so background tabs keep reporting;
    `TabStore` is one window's ordered tab list plus MRU order and the ⇧⌘T reopen stack, with
    `TabStoreDelegate` (the window controller) deciding policy. Panes are viewports: each
    displays at most one tab (`Tab.pane` back-pointer, nil = backgrounded, processes keep
    running).
  - `TabStripView.swift` — the window-level strip, its own row directly below the regular
    title bar (the title bar owns window dragging and shows the active tab's title — a tab
    drag can never move the window; `WindowRootView` lays the strip above the
    sidebar split). Custom `TabItemView`s: type icon, title (italic = preview), session dot
    (pulsing needs-input), hover/active close box, pinned tabs compact to icon-only in the left
    prefix, an amber underline tick marks tabs visible in a non-focused pane, the active tab
    (focused pane's tab) renders raised. Also the "+" new-tab button, the ✦ quick-access
    button (a new terminal tab that immediately runs `claude` with the settings-configured
    default arguments; also ⌃⌘C, the View menu and the palette), the ⌄ all-tabs menu, the
    global 5h/7d usage readout, and the drag source (`.suitTab` pasteboard = Tab.id) with an
    insertion caret for strip drops; strip-background drags are inert.
  - `TabSwitcherPanel.swift` — the ⌃Tab MRU switcher overlay: hold ⌃ to pick from the
    most-recent-first list (⌃Tab/⌃⇧Tab advance, release ⌃ commits, Esc cancels); a quick tap
    toggles between the last two tabs instantly.
  - `Pane.swift` — content-agnostic viewport chrome: the bordered `PaneContainerView` with a slim
    `PaneTitleBarView` header (type icon + title left; Claude session dot, context % and the
    exit-status dot — green clean / red non-clean — right), per-pane
    background color and screensaver menus. The focus border is derived, never pushed
    (Phase 12): `TerminalWindowController` KVO-observes `window.firstResponder` and repaints
    every pane from it in one place (`firstResponderDidChange`), so exactly one pane can render
    focused — contents don't report focus and `Pane.setFocused` is purely visual.
    `Pane.display(_:)` points the viewport at another
    tab (re-applying the pane's appearance); all tab ownership lives in `TabStore`. Interaction
    rules (the browser model): clicking a background strip tab shows it in the focused pane;
    clicking one visible elsewhere focuses that pane; closing a visible tab falls back to the
    most recent background tab or dissolves the pane; a clean shell exit closes its tab (the
    window when it's the last), a failure leaves it red. Showing a second tab is a tab
    operation (Phase 13): strip right-click ▸ Split Screen puts a background tab beside the
    active one (Unsplit dissolves its viewport). Files are regular tabs (Phase 14): every
    openFile (sidebar click, ⌘P, search, Cmd-click link) opens or re-activates the file's own
    tab, deduped by path — files never replace one another (the preview machinery survives
    only for tabs restored from old saved state).
    Drops on a pane (`TabDropTarget`): anywhere on the screen (header included) *replaces*
    what the viewport shows — the Chrome rule — with only a slim edge band (≤ 60pt) still
    splitting the tab out; the pane header still drags whole panes
    (`.suitPane`), and strip drops reorder (insertion caret) / adopt tabs across windows.
    Also defines `PaneTerminalView` (a
    `LocalProcessTerminalView` subclass that tracks its owning `Pane` and `Tab` so the window
    controller can map `window.firstResponder` back to a `Pane` and bells in backgrounded tabs
    pulse their strip item, denies OSC 52 clipboard-read queries, warns
    before pasting multi-line or curl/wget-into-a-shell text, flashes the pane on bell, and
    intercepts Cmd-clicks on SwiftTerm's implicit path-shaped links: text that resolves to a real
    file (relative to the pane's cwd, optional `:line[:col]` suffix) opens in a viewer tab at
    that line instead of going to NSWorkspace).
  - `PaneContent.swift` — the `PaneContent` protocol (what a pane hosts: view, focus target,
    title, appearance hooks, teardown) plus `TerminalPaneContent`, the shell-on-a-pty content
    (`start()` execs `/bin/zsh -l -i`). New pane kinds (file viewer, diff, search results — see
    `ROADMAP.md`) are added by implementing `PaneContent`; the split tree, title bars, focus and
    drag-rearrangement all work unchanged.
  - `SidebarView.swift` — the per-window left rail (Cmd-B): Files / Git / SSH Hosts / Notes,
    picked via an icon rail of flat hover-square SF Symbol buttons with tooltips (`RailIconView` —
    amber-tinted selection with accent icon, hover fill; Phase 9, restyled from
    NSSegmentedControl to the mockup's rail in the Phase 15 fidelity work). The Files tab
    is the `SearchView` with its search input on top and the `FileBrowserView` (handed in as the
    search view's `idleView`) below; Git hosts `GitView`; SSH Hosts hosts `SSHHostsView`;
    Notes hosts `NotesView` (selecting it puts the caret in the text).
    Width, visibility and selected tab persist via `UserDefaults` (`Tab.git`/`Tab.ssh` are
    appended after the older cases so persisted rawValues stay stable; `Tab.railOrder` places
    them next to Files). A
    `RecentFoldersView` strip sits below the tab content on every tab — the project switcher:
    the last few project roots the sidebar showed (`FavoritesStore.recentFolders`, fed by
    pinned folders and followed pane projects, current root accent-tinted); clicking a row
    pins the Files tab to that folder, right-click removes it. Below that, at the very
    bottom, `ClaudeUsageFooterView` shows Claude Code's global rate-limit usage as
    name + fill bar + % rows (5h, Week, and every model-scoped `seven_day_<model>` weekly
    the statusline reports, e.g. Fable — see `ClaudeUsage.modelWeeklies`), color-coded by
    `Theme.usageLevelColor`, "—" while no fresh `claude-status.json` exists; its gear button
    opens the Claude Code integration installer (`AppDelegate.installClaudeIntegration`).
  - `GitView.swift` — the sidebar's Git tab: the review-workflow surface merged with worktree
    orchestration. Lists the shown project's working-tree state from `GitStatusMonitor`, split
    Staged / Changes (letter-badged rows; click opens the diff tab scoped to that file via
    `TerminalWindowController.openGitDiff(root:file:)`, untracked files open in the viewer;
    right-click offers both). The header names the current branch + worktree and drops a
    switcher menu — the repo's worktrees (click = `pinSidebar(toDirectory:showFiles:false)`,
    the sidebar repoints without leaving the Git tab), local branches (click = `git checkout`,
    failures alerted), and inside a task worktree the Finish Task entries (merge/discard via
    `WorktreeTasks.finish`, then the sidebar returns to the main checkout). A "Show Full Diff"
    button mirrors ⌃⌘D scoped to the shown root; "Show Git" palette entry reveals the tab.
    Below the changes, a "Branches — N" section (Phase 21) lists the repo's local branches
    (current first) with ahead/behind vs upstream, a worktree glyph, and a dirty dot; the current
    branch renders in accent. Clicking a branch checks it out (or switches to its worktree);
    right-click offers gh actions — Create PR… / Open on GitHub / Checkout — plus a `#N` PR
    badge with a check-rollup glyph when one exists. The branch/PR data (and the graceful
    no-gh degradation) lives in `GitBranches.swift` (`GitBranchList`, `GitHubCLI`), loaded off
    the main thread. Follows/pins with the Files tab: every place the window controller
    reconfigures the browser also calls `gitView.configure(displayRoot:)`. Phase 17 File History
    section (`showFileHistory(absolutePath:)`, from the viewer's Show File History): a "File
    History — <name>" section of `GitFileHistory` commits (sha + subject + author·age rows) below
    the changes; clicking a row calls `onOpenCommitDiff` → that commit's per-file diff. Cleared
    when `configure(displayRoot:)` switches repos.
  - `Favorites.swift` — `FavoritesStore`, the persistence behind the sidebar's project
    switcher: a capped `recentFolders` list (project roots only, `$HOME` excluded; dead paths
    pruned on load) in `~/.suit/favorites.json`, posting `didUpdate`. The name is historical —
    the file once also held the removed Favorites tab's starred paths and file recents.
    The Files tab's `RootHeaderView` (in `FileBrowserView.swift`) shows the
    browsed root, a "Select Folder…" `NSOpenPanel` button, and — while pinned — an unpin button;
    a pinned root (persisted, `TerminalWindowController.pinnedSidebarRoot`) stops the browser and
    project-scoped search from following the focused pane's cwd until unpinned.
  - `ClaudeSessions.swift` — Claude session awareness (ROADMAP Phase 4). `ClaudeSessionMonitor`
    watches `~/.suit/sessions/*.json` (written by the hook/statusline scripts in
    `scripts/claude/`) plus the global `~/.suit/claude-status.json` usage snapshot, prunes
    stale files, and posts `didUpdate`. `ClaudeSessionAssigner` maps sessions onto panes: pid
    ancestry first (one sysctl read of the process table; the hook-recorded claude pid must
    descend from the pane's shell), cwd match as fallback. AppDelegate drives remapping on
    session updates plus a 3 s heartbeat.
  - Session state surfaces in pane chrome (the sidebar's Sessions tab was removed; quick
    actions live on in the palette's `Claude: …Session` entries and the composer):
    Pane title bars show session state via `PaneTitleBarView.sessionState`
    (● orange busy, pulsing yellow needs-input, green done) plus a context-fill % label
    (`contextPct`, orange ≥ 70 / red ≥ 90 — Phase 7); the exit-status dot wins after the
    shell dies. The tab strip's right end in each window shows global 5h/7d usage, color-coded.
  - `TranscriptPane.swift` — `TranscriptPaneContent` (ROADMAP Phase 7): read-only render of a
    session's JSONL transcript (`parseTranscriptLine` keeps user prompts and assistant text,
    collapses tool_use to one-line `⏺ name — summary`, drops thinking/sidechain/bookkeeping
    entries), live-tailed via a DispatchSource on the file (offset + partial-line remainder;
    auto-scrolls only when already at the bottom). Path-shaped tokens that resolve to real files
    (`resolveFileReference`, cwd-relative like the terminal's Cmd-click links) open in the viewer
    pane. Opened from the "Open Claude Transcript…" palette entry
    (multiple sessions → palette picker); one transcript pane per window, reused like viewers.
  - `StateRestoration.swift` — the Codable layout snapshot (cross-cutting "state restoration"):
    `SavedAppState`/`SavedWindow` mirror each window's ordered tab list (terminal cwd, viewer
    path + first visible line, diff root, preview/pinned flags, custom title), MRU order, active
    tab, and a `SavedNode` split tree whose leaves reference tab indices (which tabs were
    visible, plus per-pane font overrides). Captured in `applicationWillTerminate`
    (`TerminalWindowController.captureState()`), replayed by
    `init(appDelegate:startDirectory:restoring:)` — terminals restart as fresh shells in their
    old cwd, missing files/roots and transcript tabs are skipped (their panes collapse out),
    divider fractions and viewer scrolls apply after the window has its real size. Saved under
    `savedAppStateV2`; the first post-rebuild launch migrates the old per-pane snapshot
    (each pane's tabs flatten into the window list, its selected tab becomes the leaf).
  - `PromptComposer.swift` — talk-back (ROADMAP Phase 8): `SessionControl` sends text into a
    session's pty via `terminalView.send` (bracketed-paste-wrapped so multi-line payloads stay
    one input-box unit; a trailing `\r` a beat later submits; Esc interrupts), used by
    the `Claude: …Session` palette entries (session picker when
    several are live), the prompt library (`~/.suit/prompts/*.md` as "Prompt: <name>" palette
    entries sent into the focused terminal tab), and `PromptComposerController` — a floating
    multi-line composer targeting a chosen session (Enter sends, ⇧Enter newlines, Esc closes)
    with `@`-completion over the session-cwd's `FileIndex` inserting repo-relative paths. The
    terminal right-click's "Send Selection to Claude Session" opens it prefilled with the
    selection fenced in ``` so one line of context + Enter pipes an error/diff/log line over.
  - `ClaudeAttention.swift` — `ClaudeAttentionCenter` (ROADMAP Phase 7): watches session updates
    and, on a transition into needs-input while the app is inactive, posts a UNUserNotification
    (click → activate + focus that pane via `AppDelegate.focusSession(withId:)`); Dock badge =
    needs-input count; delivered notifications are withdrawn when their session is answered.
    Guarded behind `Bundle.main.bundleIdentifier != nil` — the bare swiftc dev-run binary has no
    bundle identity and UNUserNotificationCenter would trap.
  - `scripts/claude/` (repo root) — the producer side: `suit-statusline.sh` (Claude Code
    statusLine command: prints model + 5h/weekly %, mirrors usage to claude-status.json, enriches
    the session file with model/cwd plus transcript_path, session_name, context_pct and cost_usd
    when the statusline JSON carries them — all optional, `// empty`) and
    `suit-session-state.sh` (hook for UserPromptSubmit=working /
    Notification=needs-input / Stop=done; records the claude pid by walking up the process tree,
    and transcript_path from the hook JSON).
    Both bail with usage if stdin is a tty (they'd otherwise hang on `cat`) and no-op without jq.
    `build.sh` bundles them into `Contents/Resources/claude/`; they're wired up from the UI, not
    by hand — see `ClaudeIntegration.swift`.
  - `ClaudeIntegration.swift` — the installer behind "Install Claude Code Integration…" (app
    menu / palette): copies the bundled scripts to `~/.suit/scripts/` (stable across app
    moves/rebuilds; `SUIT_SCRIPTS_PATH` overrides the bundle for dev runs) and merges the
    statusLine command + the three session hooks into `~/.claude/settings.json` — other keys and
    hooks are preserved, a one-time `settings.json.suit-backup` is written before the first
    change, and a pre-existing non-Suit statusLine is called out in the confirm dialog before
    being replaced. `status()` distinguishes not-installed / outdated (installed scripts differ
    from the bundle) / installed, which the confirm dialog reflects. Resolves `~` from `$HOME`
    (not `NSHomeDirectory()`) so tests can sandbox it.
  - `RipgrepSearch.swift` — project-wide search engine (ROADMAP Phase 2): `RipgrepSearcher`
    shells out to `rg --json` (bundled into `Contents/Resources/rg` by `build.sh`;
    `SUIT_RG_PATH` overrides for dev runs), streams the JSON-lines events off the main
    thread, and delivers `SearchMatch` batches (capped at 2 000) to the main queue. Starting a
    new search cancels the previous one.
  - `SearchView.swift` — the search half of the sidebar's Files tab (Cmd-Shift-F via
    `TerminalWindowController.focusProjectSearch()`): debounced live search field, regex/case
    toggles, `-g` glob filter, and a scope picker (Project / Sub-project / Pane Directory,
    resolved by `TerminalWindowController.resolveSearchScope` — sub-project means the deepest
    `FileIndex.subprojectBadges` directory above the focused pane's cwd). Results stream into an
    `NSOutlineView` grouped by file; clicking a match opens the viewer pane at that line.
  - `CommandPalette.swift` — the Cmd-K palette: a floating panel with fuzzy type-to-filter
    (`fuzzyScore`) over `PaletteCommand`s provided by `AppDelegate`; arrows/Enter/Esc driven from
    the search field's `doCommandBy` hook. Also the machinery behind Cmd-P: the same panel shown
    with an explicit item list (every file in the project index) instead of the command provider.
  - `FileIndex.swift` — the per-project file list behind Cmd-P and the Files sidebar: cached per
    git root (`FileIndex.shared(forDirectory:)`), scanned via `git ls-files --cached --others
    --exclude-standard` (so .gitignore semantics are exact; non-git roots fall back to a capped
    FileManager walk), kept fresh by FSEvents with .git-internal events filtered out, sub-project
    roots detected by marker files (`go.mod`, `package.json`, …) for the sidebar's badges.
  - `FileViewerPane.swift` — `FileViewerPaneContent`, the read-only viewer pane (ROADMAP Phase 1):
    `NSTextView` + line-number ruler, Cmd-L go-to-line (Cmd-G being Find Next by macOS convention),
    jump-to-line with a fading highlight, selection/copy/find but no editing. Shares the terminal
    appearance settings. Phase 3 additions: syntax colors from `SyntaxHighlighter` (async for big
    files, re-applied after text-color changes) and a `MinimapView` strip on the right.
    `TerminalWindowController.openFile(atPath:line:)` re-selects the tab when the file is
    already open, otherwise opens the file in a first-class tab of its own (Phase 14 — files
    never replace one another; deduped by path). Phase 17 blame gutter: Toggle Blame (⌃⌘B /
    palette / right-click, responder-routed via `ViewerTextView.toggleBlame`) widens the
    `LineNumberRulerView` with a left column of each line's last-touching commit (short sha +
    author from `GitBlame`, `GitAgeTint`-colored, full subject on hover via `NSViewToolTipOwner`),
    and a clicked sha routes through `Pane.openCommitDiff` → `paneRequestedOpenCommitDiff` to that
    commit's diff. Show File History (`ViewerTextView.showFileHistory` → `paneRequestedShowFileHistory`)
    reveals the Git tab's history section for the open file.
  - `SyntaxHighlighter.swift` — regex-free single-pass scanner producing `SyntaxSpan`s (comments,
    strings, keywords, numbers, types, attributes, keys) for Swift/Go/JS-TS/Python/shell/JSON/
    YAML/Markdown/C-family (`CodeLanguage.detect` by extension/filename). The roadmap's sanctioned
    fallback — swappable for tree-sitter later without touching the viewer (same span output).
    Capped at 2 MB.
  - `MinimapView.swift` — the viewer's document-overview strip (ROADMAP Phase 3): run-length line
    blocks colored by syntax span (rendered once into an image), a draggable viewport rectangle
    synced to the scroll view, and `Marker` ticks (jump targets today; search/git markers as their
    phases land). Click/drag scrubs the document.
  - `DiffParser.swift` — `UnifiedDiffParser.parse` turns `git diff` text into typed `DiffLine`s
    (with old/new line numbers); `changedPaths` lists the touched files. UI-free so Phase 5 review
    sets can reuse it.
  - `DiffPane.swift` — `DiffPaneContent` (ROADMAP Phase 3): renders a diff unified or side-by-side
    (deletions/additions aligned per hunk with filler rows, scroll-locked halves), plus a Refresh
    button that re-runs the producing command. `TerminalWindowController.openGitDiff()` (View ▸
    Show Git Diff, Ctrl-Cmd-D, palette) shows `git diff HEAD` for the current project, reusing the
    window's diff pane the way openFile does. Review mode (Phase 5): n/p walk the changed files
    (anchors recorded at render time), o opens the file under review in the viewer pane.
    Phase 17: `openCommitDiff(root:file:sha:)` reuses the same diff tab to show one commit's
    per-file changes (`git show --format=`), fed by a File History row or a clicked blame sha.
  - `GitStatus.swift` — git awareness (ROADMAP Phase 5): `GitStatusMonitor` (one per repo root,
    refreshed on that root's `FileIndex.didUpdate`, i.e. FSEvents) parses `git status --porcelain
    -z` into per-path letters + changed-directory set (and the same paths split by porcelain
    column — `stagedByPath`/`unstagedByPath` — for the Git tab's sections), plus the repo shape
    (current branch, branch count, worktree count) for the Files-tab footer. Because `FileIndex` filters
    .git-internal events, the monitor also watches the git common dir with its own file-level
    FSEvents stream — refs/HEAD/packed-refs/worktrees paths only, never .git/index, which the
    monitor's own `git status` may rewrite — so commits, branch and worktree operations refresh
    it without any tracked file changing. `GitChangedLines` parses `git diff HEAD
    -U0 -- file` hunk headers into the viewer's changed-line IndexSet (orange gutter bar +
    minimap ticks).
  - `GitBlame.swift` — read-only per-file git context (ROADMAP Phase 17), both parsed off the main
    thread like `GitChangedLines`. `GitBlame.compute` runs `git blame --porcelain` into a
    `[line: BlameLine]` (sha, short sha, author, author-time, subject; the all-zero sha is
    uncommitted); `GitFileHistory.compute` runs `git log --follow` into `[FileCommit]`
    (newest-first). `GitAgeTint.color(forTime:now:)` shades recent commits bright fading to faint
    over ~2 years (log scale), amber for uncommitted — shared by the blame gutter and history rows.
  - `WorktreeTasks.swift` — worktree orchestration (ROADMAP Phase 5): `createTask` makes
    `.claude/worktrees/<slug>` on branch `task/<slug>`; `finish` merges (refusing on uncommitted
    changes) or discards, then removes worktree + branch. UI: View ▸ New Claude Task…
    (Ctrl-Cmd-T, palette) prompts for a name and opens a pane running `claude` in the new
    worktree (title = task name); right-click ▸ Finish Claude Task… (only shown inside a task
    worktree) offers Merge & Remove / Discard & Remove and closes the pane.
  - `FileBrowserView.swift` — the Files tab's tree (shown below the search input while no search
    is running): an `NSOutlineView` over `FileNode` trees built from
    the index (so it's gitignore-consistent with Cmd-P), sub-project badges, git-status letters
    (M/A/D/R/?, colored; • on directories with changes — Phase 5), expansion state preserved
    across FSEvents refreshes via path-based node equality, single click opens a file's tab
    (files are regular tabs — Phase 14). Right-click (on a row or empty space) opens a context
    menu — New File… / New Folder… (anchored on the clicked folder, a file's parent, or the
    root; names commit through `OverlayPromptController`), Rename… / Duplicate / Move to Trash
    on a row, and Reveal in Finder — with the disk op then picked up by the index's FSEvents
    rescan. Rows drag: between folders moves the file on disk, out to Finder copies it, and a
    file dropped in from Finder copies into the target folder (all keyed off the `.fileURL`
    pasteboard; drops retarget onto the hovered folder or a file's parent, refusing a folder into
    its own descendant or a name collision). Because `git ls-files` never reports an empty
    directory, a freshly-created folder is tracked in `createdDirectories` and injected into the
    tree (`FileNode.buildTree(extraDirectories:)`) so it shows at once; the set is pruned to
    still-existing dirs on rebuild and reset when the browsed root changes. A
    `GitFooterView` strip at the bottom (hidden outside git repos) shows the checked-out branch
    ("detached HEAD" when none) and the repo's branch/worktree counts from `GitStatusMonitor`.
  - `SettingsWindowController.swift` — the Cmd-, settings window, a sectioned defaults form:
    Appearance (font + default size, text color, default pane background with Reset, opacity,
    blur), Terminal (shell path — validated executable, new tabs only; cursor shape + blinking;
    bell responses: pane flash, Dock bounce), File Viewer (word wrap) and Claude (default
    session arguments — appended verbatim to `claude` by the quick-access launchers, e.g.
    "--continue" or "--model opus"). Controls write through
    to `AppDelegate`, which applies them to every window and persists; `show()` re-reads all
    state so palette/shortcut changes stay in sync. Built with `NSStackView` rather than the
    split/pane tree since its view hierarchy is never touched by `NSSplitView`'s frame management.
  - `Notes.swift` — the user's notes, a list (newest first) backed by `~/.suit/notes.json`
    (path resolves `$HOME` first so harnesses can sandbox it; a pre-list `notes.txt` is
    imported once as the first note). `NotesStore` owns the `Note` list (id + text; title =
    first non-empty line, Apple Notes style) with debounced saves (flushed in
    `applicationWillTerminate`) and a `didUpdate` notification; `NotesView` is the sidebar's
    Notes tab — a note list (add via "+", delete via right-click) over an editable NSTextView
    for the selected note, still the one deliberately editable text surface (notes are the
    user's words, not source files); typing with no note yet creates one on the fly — and the
    terminal right-click "Create Note from Selection" adds a new note through the same store,
    so open Notes tabs in every window update live.
  - `SSHHosts.swift` / `SSHPane.swift` / `SSHHostsView.swift` — the sidebar's SSH Hosts tab:
    quick-access saved SSH destinations. `SSHHostsStore` keeps connection metadata (name,
    host, user, port, auth kind, extra options) in `~/.suit/ssh-hosts.json` — **passwords
    live only in the macOS Keychain** (`SSHKeychain`, service `dev.kosych.suit.ssh`,
    account = host UUID; deleted with the host), never in JSON/UserDefaults/saved
    state/logs. Clicking a host (or its `SSH: <name>` palette entry) opens an
    `SSHPaneContent` tab — a `TerminalPaneContent` subclass (de-`final`ed for this) whose
    local shell types the composed `ssh` command (`sshCommand(for:)`, `shellQuote`);
    password hosts auto-auth via `SSHAutoAuth`, a one-shot 90s end-anchored "assword:"
    matcher fed by `PaneTerminalView.outputSniffer` (raw pty bytes) that types the Keychain
    password straight into the pty (echo is off — no scrollback leak). Restore/⇧⌘T pre-type
    the command *without* submitting (no surprise reconnects; the matcher arms on the
    user's Enter via `userReturnHook`); a deleted host restores as a plain shell. Add/edit
    via `SSHHostFormController`, an OverlayPrompt-style multi-field panel. Note: the bundle
    is ad-hoc signed, so the first Keychain read after a rebuild re-prompts — expected.
  - `PaneScreensaverView.swift` — decorative ASCII overlay (waves/stars) per pane, from the
    right-click menu, with customizable font color, font size, background color, transparency,
    and animation speed (the customization state lives on `Pane` so it survives the fresh overlay
    `setScreensaver(_:)` builds on each kind change).
  - `ProcessUtil.swift` — `ProcessExitStatus`: decodes the raw `waitpid` status word SwiftTerm
    hands back into a clean-exit/signaled distinction (Darwin doesn't expose the
    WIFEXITED/WEXITSTATUS macros to Swift). `currentWorkingDirectory(ofProcess:)`: reads a running
    process's cwd straight from the kernel via `proc_pidinfo`, used both for split-in-place-cwd and
    for persisting the last working directory on quit.
- `design/` — the visual contract: `render-reference.sh` + `reference/main.swift` regenerate
  `design/phase15-window.png`, the committed offscreen render of the reference scenario
  (pinned terminal + shell + viewer split). Re-run and commit after any chrome change so
  visual drift shows up in review diffs (ROADMAP Phase 15).
- `swift/Vendor/SwiftTerm/` — vendored (not SPM) copy of migueldeicaza/SwiftTerm's `Sources/SwiftTerm`,
  providing `LocalProcessTerminalView`.
- `Resources/Info.plist` — app bundle metadata (bundle id `dev.kosych.suit`). Add
  `NS*UsageDescription` keys here when a feature needs a permission that requires one
  (e.g. Apple Events/automation).
- `build.sh` — builds everything and assembles `build/Suit.app`.

## Build & run

```
./build.sh                        # builds swift/, assembles build/Suit.app
open build/Suit.app           # launch like a normal Mac app
```

There is no Xcode project. Do not run `xcode-select --install`, create a `.xcodeproj`, or
otherwise reintroduce Xcode/SwiftPM build tooling without checking — see "Why no SwiftPM" below.

To iterate on the Swift shell without assembling the app bundle:

```
swiftc -O swift/Sources/suit/*.swift \
  $(find swift/Vendor/SwiftTerm -name '*.swift') -o /tmp/suit-shell && /tmp/suit-shell
```

## Why no SwiftPM

This machine runs a beta Xcode Command Line Tools release (no full Xcode.app installed). On that
CLT version, `swift build` / `swift package` fail to link even a freshly-generated empty package's
own manifest (`Undefined symbols ... PackageDescription.Package.__allocating_init`). Plain `swiftc`
is unaffected. Until a fixed CLT or full Xcode is installed, SwiftTerm is vendored as source and
the Swift shell is compiled directly with `swiftc` (see `build.sh`) instead of via a `Package.swift`.
If you add a new Swift dependency, vendor its source the same way rather than reaching for SPM —
re-check whether `swift build` works before going back to a `Package.swift`.

## Workflow

Always start a new feature/task on its own new branch in its own git worktree (`EnterWorktree`) —
never work directly in the main checkout. This applies to every phase implementation from
`ROADMAP.md`: each phase must be built on its own separate branch in its own worktree, so
concurrent Claude Code sessions working other phases never interfere with each other's edits.
Multiple agents have written overlapping changes here before when working straight in the primary
working directory; a fresh branch + worktree per task keeps them from stepping on each other's
edits. Exit with `keep` if the work should persist for later, `remove` once it's merged/abandoned.

After implementing any phase from `ROADMAP.md`, document the new feature(s) in `README.md` —
write up what shipped (user-facing behavior, shortcuts, settings) as part of the same task, so
the README stays a current description of what the app does.

## Permissions / entitlements

The bundle is ad-hoc code signed (`codesign --sign -`) in `build.sh`, which is enough for TCC
(Accessibility, Full Disk Access, etc.) to track grants against `dev.kosych.suit` specifically,
rather than against Terminal.app. When a feature needs a new permission, add any required
`Info.plist` usage-description key (the OS prompt is tied to the running process, which is the
Swift binary that exec'd from inside the signed app bundle).
