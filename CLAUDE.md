# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Suit (**S**top **U**sing **I**DE **T**erminal) is a personal macOS app growing from a terminal into a Claude-code-first cockpit for
codebase work (see `ROADMAP.md` for the phased plan). Today it's a native app bundle (Dock icon,
own bundle identifier, own TCC permission entries) whose windows host split trees of terminal
panes, each running an interactive shell (`/bin/zsh -l -i`) directly via SwiftTerm's pty (see
`PaneContent.swift`). Swift/AppKit is the product/UI layer; heavy non-UI logic (indexing,
codebase analysis) may live in a Go sidecar if it outgrows Swift.

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
    task) use `OverlayPrompt.swift`, the palette-style panel (Phase 15), not NSAlert — the
    new-task prompt carries its optional "Isolate in worktree" accessory toggle (Phase 31),
    `ask(…, toggleLabel:toggleOn:) { name, isolate in … }`. Also the cross-window
    tab plumbing: `controllerAndTab(withId:)` resolves a dragged tab across windows, and
    `tearOffTab(withId:at:)` turns a tab dragged outside every window into its own window.
    Also Autopilot's host (Phase 32): the `autopilot*` settings (enabled, project root, budget
    mode, night hours, ceilings, attempt/stall caps, extra args, review model, keep-awake)
    persist like the rest with `autopilotXChanged(...)` write-throughs — enabling refuses until
    the Claude Code integration is installed; the state-dependent `Autopilot: …` palette
    entries; `AutopilotEngine.shared.tick()` on the existing 3 s session heartbeat plus
    `adoptOnLaunch()` at startup; and `focusAutopilotRunTab()` / `openAutopilotLog()` behind
    footer clicks and notification click-through.
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
    window when it's the last; Autopilot's worker tab is exempt — its exits route to the
    engine and the scrollback survives), a failure leaves it red. Showing a second tab is a tab
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
    An `AutopilotRowView` (Phase 32) sits above the usage rows while Autopilot is enabled —
    state dot + the engine's composed status ("Autopilot · next run ~03:40",
    "⚙ Phase 23 · gate: build", …), full reason as tooltip; clicking focuses the run tab
    while a run is active, opens the log otherwise.
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
    no-gh degradation) lives in `GitBranches.swift` (`GitBranchList`, `GitHubCLI` — grown
    Phase 32 Autopilot verbs: `mergePR` = `gh pr merge --merge`, deliberately no
    `--delete-branch` since the branch is checked out in a worktree; `prState` = one PR's
    state/mergedAt/body for merge confirmation and trailer reads; `isAuthenticated`; a
    `SUIT_GH_PATH` test override; `defaultBranch` made internal), loaded off the main thread. Follows/pins with the Files tab: every place the window controller
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
    session updates plus a 3 s heartbeat. Phase 32: `ClaudeUsage` also carries
    `rate_limits.*.resets_at` (parsed defensively — epoch seconds or ISO8601), and
    `readUsageSnapshot()` returns the raw values without the UI's 30-min staleness gate —
    the Autopilot scheduler applies its own policy (a stale snapshot still says *when* the
    window rolls over); the `~/.suit` paths resolve `$HOME` first so harnesses can sandbox
    both the scripts and the monitor.
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
  - `ClaudeMode.swift` — the Ask · Plan · Agent permission-mode control (ROADMAP Phase 26).
    `ClaudeMode` (ask/plan/agent) with a fixed Shift+Tab cycle order (default → acceptEdits →
    plan); `ClaudeModeControl.payload(from:to:)` is the pure `ESC[Z`×N (back-tab) string that
    cycles from a believed mode to a target; `ClaudeModeTracker.shared` remembers the last mode
    Suit sent per session, and `effectiveMode(for:)` prefers the session JSON's `permission_mode`
    readback, else last-sent, else agent. The `Claude: Ask/Plan/Agent Mode` palette entries route
    through `AppDelegate.switchClaudeMode(_:forSessionId:)`, which writes the payload and records
    the new belief (there is no per-pane title-bar control — the mode switch lives only on the
    palette). Purely a control surface — no Claude-side changes; readback is best-effort (the
    `suit-session-state.sh` hook writes `permission_mode` when the hook JSON carries it).
  - `PlanParsing.swift` / `PlanApprovalPane.swift` — the plan-approval surface (ROADMAP Phase 26).
    `PlanParser` (pure, UI-free) scans a session's JSONL transcript for the latest `ExitPlanMode`
    tool call and returns its `plan` markdown split into ordered steps (list items, else prose
    lines); `PlanApprovalAction` maps Approve & Run / Edit / Discard onto ExitPlanMode's menu
    hotkeys `1`/`2`/`3`. `PlanApprovalPaneContent` renders the plan read-only as numbered steps
    with a footer of those buttons (each dispatched via `AppDelegate.dispatchPlanApproval` →
    `SessionControl.send`) plus a Refresh that re-parses; opened by `Claude: Review Plan…`
    (`TerminalWindowController.openPlanApproval`), one per window, reused like the transcript pane.
    `scripts/mode-plan-harness.sh` compiles both pure files against a `ClaudeSession` stub and
    asserts the switch payloads, plan parsing, and approval payloads.
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
    one input-box unit; a trailing `\r` submits `submitDelay` later — 0.15 s default, 0.5 s
    for Autopilot's multi-KB prompts so the paste is consumed first; Esc interrupts), used by
    the `Claude: …Session` palette entries (session picker when
    several are live), the prompt library (`~/.suit/prompts/*.md` as "Prompt: <name>" palette
    entries sent into the focused terminal tab), and `PromptComposerController` — a floating
    multi-line composer targeting a chosen session (Enter sends, ⇧Enter newlines, Esc closes)
    with `@`-completion over the session-cwd's `FileIndex` inserting repo-relative paths. The
    terminal right-click's "Send Selection to Claude Session" opens it prefilled with the
    selection fenced in ``` so one line of context + Enter pipes an error/diff/log line over.
  - `Recipes.swift` — session task templates / recipes (ROADMAP Phase 36), the UI-free,
    standalone-compilable core (Foundation-only, verified by `scripts/recipes-test.sh`): the
    `Recipe` model with `parse(fileName:contents:)` (an optional `---`-fenced front-matter `name:`,
    else the file's base name; body after the fence) and `filled(name:selection:file:)`
    (`<NAME>`/`<SELECTION>`/`<FILE>` substitution, missing context → empty), the filename `slug`,
    and `RecipeLibrary` (the four built-ins — bug fix / feature / refactor / review — plus the
    dir-scoped `seedIfEmpty`/`load` IO). `RecipesStore.shared` layers the `~/.suit/recipes` path
    (`$HOME`-first) + a `didUpdate` on top. Surfaced by `AppDelegate.recipeCommands()` as
    "Recipe: <name>" palette entries → `launchRecipe` (OverlayPrompt for the task name + isolation
    toggle) → `TerminalWindowController.startRecipeTask` (the `startClaudeTask` recipe + the
    `startReviewPass` fixed-delay prompt send), with `recipeContext()` pulling `<FILE>`/`<SELECTION>`
    from the focused viewer/terminal. A manual, interactive launcher — no gating/auto-merge.
  - `ClaudeAttention.swift` — `ClaudeAttentionCenter` (ROADMAP Phase 7): watches session updates
    and, on a transition into needs-input while the app is inactive, posts a UNUserNotification
    (click → activate + focus that pane via `AppDelegate.focusSession(withId:)`); Dock badge =
    needs-input count; delivered notifications are withdrawn when their session is answered.
    Guarded behind `Bundle.main.bundleIdentifier != nil` — the bare swiftc dev-run binary has no
    bundle identity and UNUserNotificationCenter would trap. Also carries Autopilot's
    notifications (Phase 32) — it already owns the UNUserNotificationCenter delegate, a second
    one would fight it: `postAutopilotEvent(title:body:identifier:)` posts merged/blocked/idle
    events under stable `autopilot-*` identifiers (a newer same-kind event replaces the last;
    `autopilot-blocked` presents even while the app is active — always news), and clicks route
    by identifier prefix to `onAutopilotEvent` (run tab when open, else the log). Phase 38 adds
    the `activity-` prefix → `onActivityEvent` (the once-daily digest notification opens the
    Activity panel).
  - `Activity.swift` — the fleet activity feed / daily digest core (ROADMAP Phase 38), the
    UI-free, standalone-compilable pattern (RoadmapParser / FeedbackRouting / Recipes / FileEdit,
    Foundation-only): the `ActivityEvent` model (snake_case Codable, stable `id` the store dedups
    on) with per-kind glyph/tone/label (`ActivityKind`) and a computed `route` (session > PR >
    autopilot log > none); `ActivityFeed` (newest-first `ordered`, `filter` by repo/session/kind,
    the distinct `repos`/`kinds` menu lists); `DailyDigest.rollup(events:day:calendar:)` (one
    calendar day's counts + newest-first highlights + one-line `summary`); and `ActivityStore`
    (append-only `~/.suit/activity.jsonl`, `$HOME`-resolved, id-deduped record + amortized
    compaction, `didUpdate`). Verified by `scripts/activity-test.sh`.
  - `ActivityRecorder.swift` / `ActivityFeedController.swift` — the Phase 38 AppKit halves.
    `ActivityRecorder` is the producer: it observes `ClaudeSessionMonitor.didUpdate` and records
    session done/needs-input *transitions* (edge-triggered, first pass seeds the baseline without
    recording), exposes `record(_:)` for the direct producers (Autopilot merged/blocked via
    `AppDelegate.recordAutopilot*`, CI failures via `GitView.recordCIFailures`), and drives the
    once-daily digest (`maybePostDailyDigest`, a UserDefaults day-key gate off the 3 s heartbeat).
    `ActivityFeedController` is the reader: a floating `Activity` panel (the FleetDashboard shape)
    listing rows newest-first with a repo/kind filter and a "today" digest header, a row click
    routing via `ActivityEvent.route` to the session pane / PR on GitHub / Autopilot log. Both
    wired from `AppDelegate` (`showActivityFeed`, palette + View menu).
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
  - `SymbolIndexCore.swift` / `SymbolIndex.swift` — go-to-definition & find-references (ROADMAP
    Phase 33). `SymbolIndexCore` is the UI-free, standalone-compilable core (the
    RoadmapParser/FeedbackRouting pattern): the `SymbolDefinition` model, `parseTagLine`/
    `parseTags` over classic `ctags --fields=+n` output, `identifier(in:atUTF16Offset:)` (the
    word under a caret/click, ASCII-identifier scan), `definitions(named:in:)` and
    `referenceRegex(for:)` (the `\bNAME\b` rg pattern). `SymbolIndex` is the app shell mirroring
    `FileIndex`: `resolveCtagsExecutable()` (bundled `Contents/Resources/ctags`, `SUIT_CTAGS_PATH`
    override, universal-ctags probed via `--version` so BSD `/usr/bin/ctags` is never used),
    per-git-root cache, an off-main ctags pass over the root's `FileIndex.files` (fed on stdin,
    `-L -`) rebuilt (debounced) on `FileIndex.didUpdate`, and `definitions(for:)`. `hasCtags`
    gates the fallback: no universal-ctags → the index stays empty and callers fall back to an
    rg word search. Verified by `scripts/symbol-index-test.sh` (pure assertions + an end-to-end
    pass over a real Swift/Go fixture when ctags is installed).
  - `ReferencesPane.swift` — `ReferencesPaneContent` (ROADMAP Phase 33): the find-references pane,
    one per window reused like the diff/transcript panes. Reuses the Phase 2 search result view
    (`SearchFileGroup`/`SearchMatchNode` + `SearchFileRowView`/`SearchMatchRowView`) in its own
    `NSOutlineView`, fed by a `RipgrepSearcher` whole-word search of the symbol
    (`SymbolIndexCore.referenceRegex`) — which surfaces the definition among the uses; a header
    shows the count and, on the ctags-missing fallback path, a note. Rows click into the viewer
    via `pane.openFileLink`.
  - `FileViewerPane+Symbols.swift` — the viewer's symbol navigation (ROADMAP Phase 33): pulls the
    identifier from under the caret/selection (`symbolAtCaret`) or a document offset
    (`symbol(atCharacterOffset:)` via `lineAndColumn` + `SymbolIndexCore.identifier`) and routes
    it through the pane (`pane.goToDefinition`/`findReferences` → the host). `ViewerTextView`'s
    Cmd-`mouseDown` resolves the click to an offset and calls `goToDefinition(atCharacterOffset:)`
    (falling through to selection when it's not on a symbol); its context menu and the ⌃⌘J/⌃⌘R
    View-menu/palette entries hit `goToDefinition(_:)`/`findReferences(_:)`. The window controller
    (`TerminalWindowController+OpenTabs`) resolves definitions: exactly one jumps via `openFile`,
    several open `AppDelegate.showDefinitionPicker` (the Cmd-P palette in explicit-items mode),
    none/no-ctags open the references pane with a fallback note.
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
  - `FileViewerPane.swift` — `FileViewerPaneContent`, the viewer pane (ROADMAP Phase 1):
    `NSTextView` + line-number ruler, Cmd-L go-to-line (Cmd-G being Find Next by macOS convention),
    jump-to-line with a fading highlight, selection/copy/find. Editable since Phase 37 (see
    `FileViewerPane+Editing.swift`). Shares the terminal appearance settings. Phase 3 additions: syntax colors from `SyntaxHighlighter` (async for big
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
  - `FileEdit.swift` / `FileViewerPane+Editing.swift` — editable file viewer (ROADMAP Phase 37).
    `FileEdit.swift` is the UI-free, standalone-compilable core (the `RoadmapParser`/`Recipes`
    pattern, Foundation-only): `FileEditState` (dirty tracking — `edited(to:)` flips on first
    divergence / clears on revert/save/load) + `resolveExternalChange(diskText:bufferText:)` →
    `.ignore`/`.reload`/`.warn`, and `FileEditWriter.write` (the `.atomic` UTF-8 write). Verified
    by `scripts/file-edit-test.sh`. `FileViewerPane+Editing.swift` is the Cocoa half: the
    `NSTextViewDelegate.textDidChange` that re-runs `recomputeLineStarts`/ruler synchronously,
    bumps `loadGeneration` and debounces `rehighlight()` (~0.25 s); `save()` / a 1 s-debounced
    autosave / `flushIfDirty()` (called on tab close + `applicationWillTerminate`); and
    `reconcileExternalChange()` (checked on `NSApplication.didBecomeActiveNotification` via mtime).
    Editing is gated to real, in-bounds text — binary/too-large/unreadable stay read-only. The
    dirty flag surfaces via `Tab.isDirty`/`contentDirtyDidChange` (strip close-slot dot in
    `TabItemView`, `PaneTitleBarView.isDirty` header dot); `⌘S` is File ▸ Save / palette "Save
    File" (`ViewerTextView.saveFile`, auto-disabled via `validateUserInterfaceItem` when clean).
  - `FileTimeTravel.swift` / `FileViewerPane+TimeTravel.swift` — the file time-travel scrubber
    (ROADMAP Phase 40). `FileTimeTravel.swift` is the UI-free, standalone-compilable core (the
    `RoadmapParser`/`CommitGraph` pattern, Foundation-only): `TimeTravelTimeline` (built from the
    file's `GitFileHistory` mirrored into `TimeTravelRevision`s) maps each scrubber position to its
    `TimeTravelStop` (oldest commit … newest → working tree at the far right) and the older
    neighbour it diffs against; `TimeTravelGit` composes the `git show <sha>:<path>` /
    `git diff <old> [<new>] -U0 -- <path>` argv (working tree reads off disk, leftmost commit has
    no diff); `TimeTravelDiff.changedNewLines` parses a unified diff's +side @@ headers (shared
    with Phase 5's `GitChangedLines`); `TimeTravelHeader` composes the sha · subject · age label.
    Verified by `scripts/file-time-travel-test.sh` (a fixture repo asserting per-position content,
    diff-to-neighbour, working-tree restore, and the argv/labels). `FileViewerPane+TimeTravel.swift`
    is the Cocoa half: `toggleTimeTravel()` (⌃⌘H / View menu / palette / viewer right-click) loads
    the history and drives the read-only viewer through it via `applyStop` (git off-main, dropped by
    `loadGeneration` if the user scrubs again), hosting a `TimeTravelBarView` (header + slider +
    Diff/Exit) in the `ViewerContainerView`'s new top bar; `showTimeTravelDiff` flips into
    `openCommitDiff`, and `exitTimeTravel` reloads the working-tree file ("no residue").
    `refreshChangedLines`/`reconcileExternalChange` no-op while `isTimeTraveling` so the scrubber
    owns the buffer.
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
    Phase 34 added a whole-commit sibling `openCommitDiff(root:sha:)` (`git show --stat --patch`)
    for commit-graph node clicks (routed via `PaneHost.paneRequestedOpenCommitDiff(sha:root:)`).
  - `CommitGraph.swift` / `CommitGraphPane.swift` — the commit-graph pane (ROADMAP Phase 34).
    `CommitGraph.swift` is the UI-free, standalone-compilable core (the RoadmapParser /
    SubagentTree pattern): `parse` reads the `git log --all --date-order` `%x1f`-delimited output
    into `RawCommit`s, `layout` runs the classic swim-lane assignment (newest-first, active lanes
    each awaiting their next commit, converge forks / fan out merges) into `CommitNode`s + resolved
    `CommitEdge`s + typed ref badges, with an optional `maxNodes` cap flagging truncated parents.
    `CommitGraphPane.swift` is the Cocoa half: `CommitGraphPaneContent` (a `PaneContent` viewer
    tab, reused one-per-window like the diff/transcript panes) loads the log off the main thread,
    refreshes on `GitStatusMonitor.didUpdate`, and grows the cap via "Load more"; `CommitGraphView`
    draws the lanes/edges/nodes (age-tinted via `GitAgeTint`, HEAD/current-branch in `Theme.accent`,
    ref pills) and maps a click back to its commit sha → `Pane.openCommitDiff(sha:root:)`. Opened
    from the Git tab's graph button and the "Show Commit Graph" palette/View-menu entries;
    round-trips through state restoration (`SavedTab.kind == .commitGraph`, `graphRoot`). Verified
    by `scripts/commit-graph-harness.sh` against a fixture repo with a fork and a merge.
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
  - `FeedbackRouting.swift` — feedback-loop routing (ROADMAP Phase 29), the UI-free,
    standalone-compilable core (the `RoadmapParser`/`AutopilotScheduler`/`DiffReview` pattern,
    Foundation-only): the `FeedbackEvent` model (kind = ciFailure/prComment/mergeConflict, its
    worktree, branch, PR number, detail, and the attributed `sessionId`; `id` dedupes by
    kind+worktree+PR) plus the deterministic pieces — `conflictedFiles(porcelain:)` (unmerged
    XY codes: any `U`, `AA`, `DD`), `parsePRFeedback(json:)` / `parseFailingChecks(json:)` over
    gh's `reviews,comments` / `statusCheckRollup` JSON, `attributeSession(worktreePath:sessions:)`
    (a single physical-path cwd match wins; 0 or >1 → nil so routing falls back to a picker,
    never guesses), and `composePrompt(for:)` / `reviewPassPrompt(for:)` (fenced so bracketed
    paste keeps the log/comments one input unit). Verified by `scripts/feedback-routing-test.sh`.
  - `FeedbackInbox.swift` — the Phase 29 IO layer: `FeedbackInbox.gather(root:prByBranch:sessions:)`
    iterates the repo's worktrees (`git worktree list --porcelain`), reads each one's conflict
    state (pure git, so conflicts show without gh), and — for worktrees whose branch has an open
    PR — pulls failing-check detail + a failed-run log tail and PR review comments via the new
    `GitHubCLI.failingChecks` / `failedRunLog` / `prFeedback`, attributing each event to its
    session. Runs off the main thread; takes a `SessionRef` snapshot read on the main thread so
    it never touches `ClaudeSessionMonitor` off-thread. Surfaced by `GitView+Feedback.swift` (the
    Git tab's top "Feedback — N" section + `GitFeedbackRowView`, loaded token-guarded like the
    branch pass) and routed by `AppDelegate.routeFeedback(_:)` → `SessionControl.send` (the
    resolved session, else the `withSession` picker) with palette verbs "Show Feedback Inbox" /
    "Route Feedback to Session…"; the reviewer-agent lane is `TerminalWindowController.startReviewPass(for:)`.
  - `PRReview.swift` / `GitView+PRInbox.swift` — the GitHub PR review inbox (ROADMAP Phase 39).
    `PRReview.swift` is the UI-free, standalone-compilable core (the Recipes / FeedbackRouting
    pattern, Foundation-only): the `PRReviewItem` model + `PRReviewInbox.parseList` (over
    `gh pr list --json number,title,author,headRefName,url,statusCheckRollup`) / `summarizeChecks`,
    the `PRReviewDecision` enum (→ `--approve`/`--request-changes`/`--comment`, `requiresBody`), and
    `PRReviewComposer` (`composeBody` folds a `[DiffReviewComment]` draft into the review body
    grouped by file / sorted by line; `reviewArguments` builds the exact `gh pr review` argv).
    Verified by `scripts/pr-review-test.sh`. The gh shell-outs are `GitHubCLI.reviewInbox` (two
    `--search` passes — `involves:@me` + `review-requested:@me` — unioned) / `prDiff` / `prReview`,
    all off-thread with the Phase 21 no-gh degradation. `GitView+PRInbox.swift` is the Git-tab
    surface: `loadReviewInbox()` (token-guarded off-thread load), the "PR Review Inbox — N" section
    + `GitPRInboxRowView`, and the row context menu (Review Changes / Open on GitHub). A row click
    fires `GitView.onOpenPR` → `TerminalWindowController.openPRDiff(_:)`, which fetches `gh pr diff`
    off-thread into the window's `DiffPaneContent` (tagged `reviewingPR`); the diff's Review menu
    "Submit as PR Review…" → `AppDelegate.submitPRReview(from:)` pops the verdict+note dialog and
    posts via `GitHubCLI.prReview`. Palette: "Show PR Review Inbox" / "Submit PR Review…".
  - `WorktreeTasks.swift` — worktree orchestration (ROADMAP Phase 5): `createTask` makes
    `.claude/worktrees/<slug>` on branch `task/<slug>`; `finish` merges (refusing on uncommitted
    changes) or discards, then removes worktree + branch. `removeAfterRemoteMerge` (Phase 32)
    cleans up after Autopilot's PR flow, where the merge already happened on GitHub: force
    worktree removal (the build gate leaves an untracked `build/` that a plain remove refuses),
    local `branch -D`, best-effort remote branch delete — `finish` stays untouched and unused
    by Autopilot. UI: View ▸ New Claude Task… (Ctrl-Cmd-T,
    palette) prompts for a name plus an "Isolate in worktree" toggle (Phase 31) and opens a pane
    running `claude` (title = task name); right-click ▸ Finish Claude Task… (only shown inside a
    task worktree) offers Merge & Remove / Discard & Remove and closes the pane. The isolation
    branch lives in `TerminalWindowController.startClaudeTask(named:isolate:)` — on = `createTask`
    worktree (the original behavior), off = run in the current checkout — with the pure decision
    (`usesWorktree` / `checkoutDirectory`) factored into `TaskLaunch.swift` for the harness, and
    the prompt default in `AppDelegate.taskIsolateByDefault` (Settings ▸ Claude).
  - `TaskLaunch.swift` / `SubagentTree.swift` — the Phase 31 UI-free, standalone-compilable cores
    (the RoadmapParser / FeedbackRouting pattern). `TaskLaunch` is the per-task isolation decision.
    `SubagentTree.build(sessions:worktrees:)` turns the flat session map + `git worktree list` into
    a session-anchored nested forest: a worktree nests under its nearest *session* ancestor (via
    `.claude/worktrees/` containment), so a session's `isolation: worktree` subagents render
    indented under it while a session-less checkout that merely *contains* a session (the main
    repo) stays transparent; pruning is implicit (a removed worktree drops out of the list).
    `FleetDashboard`'s list weaves the tree in (`FleetModel.tree`, `FleetRow.depth/isBareWorktree`,
    off-thread `git worktree list` cache), rendering bare subagent worktrees muted and
    unsteerable. Verified by `scripts/isolation-harness.sh`.
  - `AutopilotEngine.swift` — Autopilot (ROADMAP Phase 32): the app works through `ROADMAP.md`
    autonomously, one run at a time. A main-queue state machine (off / idle / running / paused /
    blocked(reason) / doneAllPhases — the last auto-recovers when ROADMAP.md's mtime changes)
    ticked from AppDelegate's 3 s session heartbeat, throttled internally (budget math every
    tick from the cached usage snapshot, roadmap mtime ~10 s, git/gh polls ≥30 s, one
    `inFlight` flag; a monotonic `generation` token drops stale background callbacks). A run:
    preflight (ordered — project root set, eligible phase, gh installed + authenticated, main
    checkout on the default branch / clean / ff-synced, no leftover task worktree; each failure
    a distinct `AutopilotBlockReason`) → `WorktreeTasks.createTask` → a visible `⚙ Phase N`
    run tab (`TerminalWindowController.openAutopilotRunTab`, the startClaudeTask recipe minus
    worktree creation, inserted without stealing focus, typing
    `claude --dangerously-skip-permissions` + the extra args) → two-stage prompt delivery (the
    multi-KB worker prompt is pasted via `SessionControl.send` only once the run's session file
    appears, which also pins the session; 20 s timeout covers the one-time permissions dialog)
    → `working`, where session `done` only *triggers* verification against world state —
    commits ahead + branch pushed + PR with the `Autopilot-Phase` trailer + clean worktree +
    ✅ heading; the Stop hook is never trusted, and misses are nudged back into the live
    session (≥2 min apart, max 5) → build gate → review gate (failures/rejections feed the log
    tail / findings back into the session and return to `working`, attempts capped) →
    `GitHubCLI.mergePR` confirmed against `prState == MERGED` ("not mergeable" feeds conflict
    instructions back) → cleanup (main-checkout ff-sync, `removeAfterRemoteMerge`, history row,
    notification, tab close) → idle, looping to the next phase. Watchdogs: a dead worker
    respawns once with `--continue` (tab exits route here via a `tabProcessDidExit` intercept
    that also skips the clean-exit auto-close so the scrollback survives), a needs-input stall
    gets one best-judgment nudge then blocks, 90-min wall clock per attempt. Any block halts
    Autopilot (worktree/branch/PR/logs kept); palette Retry clears it, Skip Current Phase
    appends ⏸ to the heading — the engine's one sanctioned ROADMAP.md write.
    `adoptOnLaunch()` resumes a persisted run at the right stage after a relaunch (pure
    `adoptionStage` truth table over worktree existence + PR state). Holds
    `idleSystemSleepDisabled` across runs when keep-awake is on.
  - `AutopilotScheduler.swift` — the engine's budget math, pure and standalone-compilable for
    the scratch logic tests: `mayStartRun(mode:snapshot:now:config:)` returns `.go` or
    `.wait(until:why:)` (both feed the footer row) from a `UsageSnapshot` — raw percentages
    plus parsed `resets_at`, deliberately without the UI's 30-min staleness gate;
    `effectivePct` treats never-measured as 0 (optimistic — the interactive worker refreshes
    usage within ~1 min) and zeroes a percentage whose window rolled over since capture.
    Modes (`AutopilotBudgetMode`, Settings ▸ Autopilot): pace-to-reset (usage must trail the
    elapsed-fraction-of-week × target pace line; no resets_at falls back to max-out), max-out
    (go while under the weekly ceiling) and night-shift (max-out inside the midnight-wrapping
    [start, end) hour window). The 5h ceiling and weekly hard stop gate all modes, and the
    model-scoped weeklies bind via max() with the all-models weekly. Budget gates *starting*
    only — an in-flight run always finishes.
  - `RoadmapParser.swift` — ROADMAP.md as Autopilot's steering interface (pure static, no app
    dependencies): parses `### Phase N — Title` headings into `RoadmapPhase`s (body up to the
    next `##`/`###`; `slug`/`branch` kept a fixed point of `WorktreeTasks.slug`, so the
    worktree/branch the engine creates match the phase's identity). ✅ anywhere in a heading =
    shipped (covers the "(…)" parenthetical variants), ⏸ = skipped, `eligiblePhase` = the
    first phase that is neither, in document order — reordering phases is the priority UI.
    `specText` (heading + body) is what gets snapshotted into the worker prompt and review
    gate; `markingPhaseSkipped` is the text transform behind Skip Current Phase.
  - `AutopilotStore.swift` — Autopilot persistence under `~/.suit/autopilot/`, the
    FavoritesStore pattern (`$HOME`-resolved paths, atomic writes, `didUpdate`) but
    Foundation-only: `state.json` holds the current `AutopilotRun` (stage, attempt counters,
    pinned session, the verbatim spec snapshot, cost/context sampled from the session file
    because session files get pruned) plus the block/pause flags and last usage snapshot,
    rewritten on every transition; `history.jsonl` appends snake_case `CompletedRun` rows
    (outcome merged/blocked/skipped/aborted); `autopilot.log` is the human-readable event log
    ("Autopilot: Show Log" opens it as a regular viewer tab); `logs/<slug>/build-N.log` /
    `review-N.log` capture gate output. Tab ids are per-launch UUIDs and never persisted —
    relaunch adoption re-resolves or respawns.
  - `AutopilotGates.swift` — the two pre-merge checks, background-queue `Process` wrappers
    (Foundation-only) that stream stdout+stderr into the attempt's log file and
    watchdog-terminate overruns (SIGTERM, SIGKILL 10 s later): `AutopilotBuildGate` runs the
    worktree's own `build.sh` (15-min timeout); `AutopilotReviewGate` runs headless
    `claude -p --output-format text` (10-min timeout) with the review prompt fed on stdin —
    never argv, so no quoting/length hazards — and the claude binary resolved via
    `SUIT_CLAUDE_PATH` → known install paths → login-shell `command -v`, mirroring
    GitHubCLI's gh probing. `ReviewVerdict.parse` reads only the output's final non-blank line
    and demands `VERDICT: APPROVE|REJECT` exactly; anything else is a parse failure —
    ambiguity is never an approve.
  - `AutopilotPrompts.swift` — pure prompt/message composition for the runs: the worker
    instruction block (the phase spec embedded verbatim; the template is overridable via
    `~/.suit/autopilot-prompt.md` with `<N>`/`<TITLE>`/`<SLUG>`/`<WORKTREE_PATH>`/`<SPEC>`
    placeholders, `<SPEC>` substituted last so placeholder-shaped spec text is never
    re-substituted), the resume prompt for `--continue` respawns/adoption, the feedback
    messages typed back into the live session (missing-output nudges, the stall nudge,
    build-failure log tails — fenced so bracketed paste keeps them one input unit —
    review-rejection findings, merge-conflict instructions), and the review-gate prompt:
    CLAUDE.md capped at 40 KB and the PR diff at 150 KB with explicit truncation headers,
    clipped on UTF-8 boundaries.
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
    bell responses: pane flash, Dock bounce), File Viewer (word wrap), Claude (default
    session arguments — appended verbatim to `claude` by the quick-access launchers, e.g.
    "--continue" or "--model opus") and Autopilot (Phase 32: the enable checkbox — snapped
    back if `autopilotEnabledChanged` refuses; a validated project root field + Choose…
    NSOpenPanel; budget mode popup with night-hour steppers enabled only in night mode; the
    5h/weekly/hard-stop/pace percentage steppers; attempt and stall caps; extra worker args —
    kept newline-free; review model; keep-awake). Controls write through
    to `AppDelegate`, which applies them to every window and persists; `show()` re-reads all
    state so palette/shortcut changes stay in sync. Built with `NSStackView` rather than the
    split/pane tree since its view hierarchy is never touched by `NSSplitView`'s frame
    management (the form scrolls now — the Autopilot section pushed it past the window height).
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

## Testing

There is no XCTest target (no SwiftPM/Xcode project — see above). Instead, the pure, UI-free
logic that features rest on is verified by **standalone harnesses**: each compiles just the
relevant Foundation-only source file(s) against a small assertion driver and runs it — no app, no
UI. Run them all from one entrypoint:

```
scripts/test.sh                   # fast suite (feedback-routing + mode-plan + broadcast + recipes + file-edit + activity + pr-review + file-time-travel), ~seconds
scripts/test.sh --all             # + the autopilot pipeline harness (~4 min)
scripts/test.sh --list            # list the harnesses
```

The individual harnesses (each also runnable directly) are `scripts/feedback-routing-test.sh`
(`FeedbackRouting.swift`), `scripts/mode-plan-harness.sh` (`ClaudeMode.swift` + `PlanParsing.swift`),
`scripts/recipes-test.sh` (`Recipes.swift` — recipe parse / substitution / seed / load),
`scripts/file-edit-test.sh` (`FileEdit.swift` — dirty transitions / external-change reconcile /
atomic write, Phase 37), `scripts/activity-test.sh` (`Activity.swift` — feed ordering / row
routing / repo·kind filtering / daily-digest rollup / append-only store dedup + round-trip,
Phase 38), `scripts/pr-review-test.sh` (`PRReview.swift` — `gh pr list` parse / review-body
compose / `gh pr review` argv, Phase 39), `scripts/file-time-travel-test.sh`
(`FileTimeTravel.swift` — a fixture repo asserting the timeline shape, per-position content via
the real `git show` argv, diff-to-neighbour, working-tree restore, and the header labels,
Phase 40), and `scripts/autopilot-harness.sh` (the full Autopilot pipeline, offscreen with
everything faked).
This is why testable logic is kept in Foundation-only files with no app dependencies (the
`RoadmapParser`/`AutopilotScheduler`/`FeedbackRouting` pattern) — a harness can compile it in
isolation. When you add such logic, add a harness for it and wire it into the `HARNESSES` list in
`scripts/test.sh`. UI/chrome changes are instead guarded by the committed reference render — see
`design/render-reference.sh` (ROADMAP Phase 15).

## Agent tooling

This repo is set up for coding agents (Claude Code and others):

- `AGENTS.md` — the concise front-door / 60-second orientation (this `CLAUDE.md` remains the
  source of truth for the full file map and rationale). Keep the two in sync when the build/test
  commands or the load-bearing rules change.
- `.claude/commands/` — repo slash commands: `/build`, `/test`, `/claim-phase`,
  `/render-reference`, `/orient`, `/find-file` (quick file search by name).
- `.claude/settings.json` — if present, the shared permission allowlist for the safe, repeated
  commands (build, `swiftc`, `scripts/test.sh`, read-only `git`/`gh`, search) so agents aren't
  prompted mid-loop. It intentionally does **not** auto-allow `git push` (asks) or force-push
  (denied). `.claude/worktrees/` stays git-ignored.

## Workflow

Always start a new feature/task on its own new branch in its own git worktree (`EnterWorktree`) —
never work directly in the main checkout. This applies to every phase implementation from
`ROADMAP.md`: each phase must be built on its own separate branch in its own worktree, so
concurrent Claude Code sessions working other phases never interfere with each other's edits.
Multiple agents have written overlapping changes here before when working straight in the primary
working directory; a fresh branch + worktree per task keeps them from stepping on each other's
edits. Exit with `keep` if the work should persist for later, `remove` once it's merged/abandoned.

**Claim a phase before you start it, so concurrent sessions don't collide.** The moment you pick
a `ROADMAP.md` phase to implement, mark it claimed by appending ` 🚧 in progress (<branch>, <date>)`
to that phase's `### Phase N — …` heading in `ROADMAP.md` on the main checkout, and commit just
that one-line change to main before creating the worktree. Before picking a phase, read the
`ROADMAP.md` headings and skip any already marked `🚧` (claimed), `✅` (shipped), or `⏸` (skipped) —
take the first phase in document order that has none of these. Replace the `🚧` marker with `✅`
when the phase ships (or remove it if you abandon the work) so the roadmap stays truthful.

After implementing any phase from `ROADMAP.md`, document the new feature(s) in `README.md` —
write up what shipped (user-facing behavior, shortcuts, settings) as part of the same task, so
the README stays a current description of what the app does.

**Every `/goal` implementation follows the full loop.** Whenever you take on a task via `/goal`,
carry it end to end without being asked each time:

1. Create a **new branch in its own new git worktree** (`EnterWorktree`) and implement the task
   there — never in the main checkout, same as any other task above.
2. When the implementation is finished, **create a PR** (`gh pr create`) targeting `main`.
3. **Try to merge it** (`gh pr merge`), and **resolve all conflicts** that come up — pull/rebase
   `main` in, fix the conflicts, and re-push until the PR is mergeable and merged.

Only stop once the PR is merged (or you've surfaced a genuine blocker you can't resolve). This is
the default contract for `/goal` work; you don't need to ask the user to confirm each step.

## Permissions / entitlements

The bundle is ad-hoc code signed (`codesign --sign -`) in `build.sh`, which is enough for TCC
(Accessibility, Full Disk Access, etc.) to track grants against `dev.kosych.suit` specifically,
rather than against Terminal.app. When a feature needs a new permission, add any required
`Info.plist` usage-description key (the OS prompt is tied to the running process, which is the
Swift binary that exec'd from inside the signed app bundle).
