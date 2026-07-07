# Suit Roadmap

Expanding Suit from a terminal app into a **native macOS cockpit for driving Claude Code
across a monorepo** — you navigate, review, and orchestrate; Claude writes.

## Product thesis

Not an IDE. An IDE assumes *you* type the code. Suit assumes *Claude* types the code, so the
app optimizes for the human's actual jobs: **finding things, reading things, reviewing changes,
and directing multiple sessions.** Every feature must pass the test: "does this help me steer
Claude or verify its work faster?"

Core decisions (settled):

- **Viewer-first, not editor.** Rich read-only file viewing (highlighting, minimap, diffs,
  jump-to-line). Editing happens through Claude or `$EDITOR`. Selection+copy and jump-to: yes;
  typing into the buffer: no. Light editing, if ever, is an additive later phase — not a rewrite.
- **Native AppKit UI.** File browser, search, viewer, minimap are NSViews in the existing split
  tree / a new sidebar — not TUI panes.
- **Claude-first means all four pillars**: session awareness, review workflow, monorepo
  navigation, and multi-session orchestration.

## Architecture evolution

The current structure survives, but two rules change:

1. **"Swift stays minimal" is revised.** Swift/AppKit becomes the product layer. Heavy non-UI
   logic (indexing, monorepo analysis) may move to a Go sidecar later if it gets big. (The Bubble
   Tea status-footer TUI that used to live in `go/` has been removed.)
2. **`Pane` generalizes.** Today a pane *is* a terminal. Introduce a `PaneContent` protocol so
   the existing `NSSplitView` tree, title bars, focus tracking, and drag-and-drop host any pane
   kind:
   - `TerminalPaneContent` (today's behavior, unchanged)
   - `FileViewerPaneContent`, `DiffPaneContent`, `SearchResultsPaneContent`, …

   This is the single most important refactor — done early, every later feature is "just another
   pane kind" and inherits splitting, rearranging, cwd logic, and persistence for free.
   Phase 6 extends this a second time: a pane goes from hosting any *kind* of content to hosting
   any *number* of them (a tabbed group).

Plus one new top-level layout element: a collapsible **sidebar** (Files / Search / Sessions)
outside the split tree; the split tree stays the content area.

```
┌──────────────────────────────────────────────────────────────┐
│ ⌘P fuzzy-open · ⌘⇧F search · ⌘K command palette   [usage ▓▓] │
├───────────┬──────────────────────────────┬───────────────────┤
│ SIDEBAR   │  viewer: Pane.swift        ▒ │ term: claude ●busy│
│ ▾ go/     │  120  func (p *Pane)…      ▒ │                   │
│ ▾ swift/  │  121    …                  ▒ │ > refactoring…    │
│   M Pane… │                     minimap▒ ├───────────────────┤
│ ▾ docs/   │                            ▒ │ term: zsh         │
│ [files|🔍|├──────────────────────────────┤                   │
│  sessions]│  diff: swift/…/Pane.swift    │ $                 │
└───────────┴──────────────────────────────┴───────────────────┘
```

## Phases

Since Phase 32 this file is also **Autopilot's steering interface**, re-parsed at every
scheduling decision: **priority = document order** (reordering phases is the priority UI),
`✅` anywhere in a phase heading = shipped, `⏸` anywhere in a heading = skipped. A running
worker holds a snapshot of its phase's spec taken at spawn, so mid-run edits only affect the
next scheduling decision.

### Phase 0 — Foundations (enables everything else) — ✅ shipped

- `PaneContent` protocol refactor; terminal panes ported onto it.
- Sidebar shell (collapsible, tabbed: Files / Search / Sessions), `⌘B` toggle.
- Command palette (`⌘K`) — a floating panel; every later feature registers commands here instead
  of growing the menu bar forever. This is the "works for the user" backbone: everything
  reachable by keyboard, nothing requires mousing through chrome.
- Update CLAUDE.md architecture notes.

### Phase 1 — Navigate (file browser + fuzzy open + viewer) — ✅ shipped

- **File browser sidebar**: lazy `NSOutlineView`, FSEvents-driven refresh, `.gitignore`-aware.
  **Monorepo-aware from day one**: detect sub-project roots (`go.mod`, `package.json`,
  `Package.swift`, `Cargo.toml`, `pyproject.toml`…) and render them as first-class sections with
  language badges, not just folders.
- **Fuzzy file opener** (`⌘P`): in-memory file list from the FSEvents-watched tree; fzf-style
  scoring is a few hundred lines of Swift. Highest-leverage navigation feature there is.
- **File viewer pane**: read-only `NSTextView` + CoreText, line numbers, `⌘G` go-to-line, smooth
  scrolling. Monospace; uses the same appearance settings as terminals. Opening a file from
  browser/palette opens (or reuses) a viewer pane in the split tree.
- **Terminal → viewer linking**: detect `path/file.swift:123` patterns in terminal output
  (SwiftTerm exposes the buffer), make them clickable → opens viewer at that line. The killer
  interaction for reviewing Claude's terminal output.

### Phase 2 — Search — ✅ shipped

- **Engine: shell out to `rg --json`**. Don't write a search engine; ripgrep is the industry
  answer (VSCode does exactly this). Bundle the `rg` binary in `Contents/Resources` so the app
  doesn't depend on the user's PATH.
- **Search sidebar/pane** (`⌘⇧F`): live-updating grouped results, regex/case/glob toggles,
  click → viewer at match.
- **Scope control**: whole repo / current sub-project / current pane's cwd. For monorepos this
  is the difference between usable and noise.
- **Search-in-file** (`⌘F`) in viewer panes, with matches marked on the minimap (Phase 3).

### Phase 3 — Read well (highlighting, minimap, diffs) — ✅ shipped (regex highlighter; tree-sitter still open as a swap-in)

- **Syntax highlighting**: vendor **tree-sitter** (plain C — compiles fine under the no-SwiftPM
  constraint, just more objects in `build.sh`) plus grammars for the actual languages in use
  (Go, Swift, TS/JS, Python, Markdown, JSON, YAML, shell). Start with those eight; add on demand.
- **Minimap**: a custom `NSView` strip rendering the whole document as ~2px-tall scaled line
  blocks (colored run-length blocks from tree-sitter tokens — faster than tiny CoreText and
  looks identical at that size). Draggable viewport rectangle, and — the real value — **overlay
  markers**: search hits, git-modified regions, diagnostics later. The minimap is the "where is
  stuff in this file" instrument, not decoration.
- **Diff pane**: side-by-side and unified, driven by `git diff` output. Gets heavy use in
  Phase 5.

### Phase 4 — Claude session awareness — ✅ shipped (hooks wiring into Claude Code settings is a manual step; see scripts/claude/)

The plan (a `statusline.sh` → `~/.suit/claude-status.json` seed existed in the removed Go
TUI and can be recreated as a plain script when this phase lands):

- **Per-session state files**: Claude Code **hooks** (Notification, Stop, PreToolUse) plus the
  statusline write `~/.suit/sessions/<session-id>.json` — state (working / waiting-for-input
  / done), cwd, current task summary, usage.
- **Pane ↔ session mapping**: walk each terminal pane's child process tree to find `claude`
  processes and match them to session files (by pid or cwd).
- **Attention routing**: pane title bar shows ● busy / ◐ needs-input / ✓ done; a session that
  needs input gets a subtle pulse + optional notification; the Sessions sidebar tab lists all
  sessions sorted by "needs you first." You never poll panes to see who's stuck.
- Global usage bars render natively in the window (title bar accessory), visible regardless of
  pane contents.

### Phase 5 — Review workflow + orchestration — ✅ shipped

- **Git awareness everywhere**: `git status --porcelain -z` + FSEvents → modified/added badges
  in the file browser, changed-region marks in viewer gutters and minimap.
- **"What did Claude change?" review mode**: when a session finishes, one keystroke opens a
  review set — diff panes for every file that session touched, walkable with n/p. Approve → tell
  Claude to commit; reject → jump back into that pane with context.
- **Worktree orchestration** (the CLAUDE.md workflow, productized): "New task" command → creates
  a worktree, opens a terminal pane in it running `claude`, tags the pane with the task name.
  Sessions tab shows task → worktree → session → status. Finish → merge/remove the worktree from
  the same UI. Turns the documented multi-agent discipline into a one-keystroke habit.

### Phase 6 — Tabbed panes (decouple "open" from "visible") — ✅ shipped (incl. the state-restoration follow-up)

Today every open pane is a visible leaf of the split tree, so screen size caps how much can be
open (`minPaneWidth`/`minPaneHeight` gate splits), and `openFile` compensates by allowing only
one viewer pane per window — which also means you can never read two files side by side. Adopt
the VS Code **editor group** model: a split-tree leaf becomes a *pane group* hosting any number
of tabbed contents, one visible at a time. Splits control how many groups are visible at once;
tabs make the open set unbounded.

- **`Pane` generalizes again**: from one immutable `PaneContent` to an ordered list of contents
  plus an active index. `PaneContainerView`'s title bar grows into a tab strip (it already owns
  the title + status dot + drag machinery); each tab shows its content's title and its own
  status dot. Everything is tabbable — terminals, viewers, diffs — so a shell can sit behind a
  file tab.
- **Attention still routes through hidden tabs**: the per-tab dot carries Claude session state
  (busy / needs-input / done), exit status, and bell flashes, so a backgrounded terminal can't
  get stuck silently. A group's title-bar dot rolls up its noisiest tab.
- **Preview-tab open semantics** (VS Code style): `openFile`/search/`⌘P` load into the group's
  single *preview* tab, replaced by the next open; double-click or pin (⌘-click, palette
  command) makes it permanent. Browsing stays cheap, accumulating tabs is deliberate — this
  replaces the old "one viewer pane per window" rule.
- **Read multiple files at once**: since viewers are ordinary tabs, split any tab out into its
  own group (drag a tab to a pane edge, or a "Split tab right/down" command) to view files side
  by side. The diff pane gets the same treatment.
- **Keyboard-complete**: ⌘1..9 keeps addressing visible groups; add tab cycling
  (⌃Tab / ⇧⌃Tab and ⌘⇧[ ⌘⇧]), "go to tab N" within a group, and ⌘W closes the active tab
  first, then the group when its last tab closes. Overflowing tab strips scroll/condense; a
  palette command lists all open tabs across groups (fuzzy-jump).
- **Drag & drop, two grains**: dragging a *tab* reorders within a strip, moves it to another
  group, or drops on a pane edge to split; dragging the *title bar background* keeps today's
  whole-group rearrangement.
- **Mechanics to respect**: only the active tab's `focusTarget` is first-responder-eligible
  (hidden views stay alive but unfocusable); closing a group tears down *all* its contents;
  `focusedPane()`'s firstResponder→container walk keeps working since groups are still
  `PaneContainerView`s.
- **Sets up state restoration**: an unbounded open set is the first thing worth serializing —
  layout + tabs + scroll positions (extends the cwd persistence; can land as a follow-up).

### Phase 7 — See what Claude is doing (transcript, context, escalation) — ✅ shipped

The Sessions tab says *that* Claude is busy; this phase shows *on what*, and makes "needs you"
reach you even when Suit isn't frontmost. All read-side — nothing in this phase types into
a session.

- **Richer session files**: the hook/statusline scripts additionally merge `transcript_path`,
  `session_name`, context-window usage (`context_window.used_percentage`) and cost from the
  statusline JSON into `~/.suit/sessions/<id>.json` — defensively (`// empty`), since these
  fields vary across Claude Code versions. Everything below is just a consumer of that file.
- **Transcript pane** (`TranscriptPaneContent`): renders a session's JSONL transcript read-only
  — prompts, assistant text, tool calls collapsed to one-line summaries — and live-tails the
  file while Claude works. File paths in it are clickable via the same openFile plumbing as
  terminal output. Opened from a Sessions row (double-click / context menu) or the palette;
  reuses one transcript pane per window, like viewers and diffs. Review what Claude *did*, not
  just what it printed.
- **Per-pane context meter**: context fill % in the pane title bar next to the session dot,
  amber then red as it nears compaction. The "should I /compact or let it ride" glance.
- **Native attention escalation**: a session flipping to needs-input while the app is inactive
  posts a user notification (click → activate + focus that pane); the Dock badge counts
  sessions waiting on you and clears as they're handled. Still never steals focus — escalation
  is opt-in by clicking.

### Phase 8 — Talk back (steer sessions without touching their panes) — ✅ shipped (Send Selection opens the composer prefilled rather than submitting blind)

Writing into a claude pane's pty (`terminalView.send`) — text arrives as if typed, so no new
protocol, no Claude-side changes. The app becomes a control surface for many sessions, not just
a viewer of them.

- **Session quick actions** (Sessions-row context menu + palette): Continue, /compact,
  Interrupt (Esc), and answer-needs-input (focus the pane, optionally with prefilled text).
- **Prompt composer**: a floating panel (the command-palette machinery grown a multi-line text
  view) targeting a chosen session; @-completion over `FileIndex` inserts repo-relative paths;
  Enter sends, Shift-Enter newlines.
- **Send Selection to Claude Session** in the terminal right-click menu (next to "Create Note
  from Selection") — pipe an error, a diff hunk, a log line straight into a session.
- **Prompt library**: `~/.suit/prompts/*.md` surfaced as palette entries ("Prompt: <name>")
  that send into the focused claude pane. Saved prompts as files, not a settings UI.

### Phase 9 — Sidebar rail: icon tabs, explicit folder scope, favorites — ✅ shipped

The sidebar's Files/Sessions segmented text control doesn't scale — every new surface (favorites
now, git/review views later) would widen it in a rail that's only 180–420pt wide. Replace it with
an **icon rail** and make the Files tab's scope a deliberate choice instead of an inference.

- **Icon tabs**: swap the segmented labels for compact template-image icons (SF Symbols: folder
  for Files, terminal/sparkle for Sessions, star for Favorites) with tooltips and the selected
  state clearly marked. Same `Tab` enum + `UserDefaults` persistence underneath; `⌘B` /
  `⌘⇧F` behavior unchanged. Adding a future tab becomes one enum case + one symbol.
- **Select a folder (Files tab)**: today the browser root is always derived — the focused pane's
  git root via `FileIndex.shared(forDirectory:)`, following the pane as `currentFileIndex()`
  retargets. Add an explicit "Select Folder…" affordance (header button on the Files tab +
  palette command) that opens an `NSOpenPanel` and pins the browser/search to that directory;
  a pinned root stops following pane cwds until unpinned (header shows the root name + an
  unpin control). Persists per window like the sidebar width.
- **Favorites tab, with recent suggestions**: star files/folders from the browser's context menu
  (and a palette command); the Favorites tab lists them on top, and below a **Recents** section
  suggests recently opened files and recently pinned/visited folders (fed by `openFile` and the
  folder picker), most recent first. Click behaves like a browser row: files → viewer pane,
  folders → pin the Files tab there. Stored in `~/.suit/favorites.json` + a capped recents list,
  so it survives rebuilds and is shared across windows.

### Phase 10 — Browser tabs (one strip owns every open thing) — ✅ shipped

Phase 6's per-pane tab groups replaced wholesale by the browser model (design artifact:
"Suit — Browser Tabs Redesign"): a single window-level strip in the title-bar row owns every
tab — terminal, viewer, diff, transcript — and split-tree panes are *viewports* displaying a
subset of them. Clicking a background tab shows it in the focused pane; clicking a visible one
focuses its pane; the strip always reads the layout (active = raised, visible-elsewhere = amber
tick). `TabStore` (ordered tabs + MRU + reopen stack), `TabStripView` (custom strip, pinned
icon-only prefix, overflow ⌄, usage readout), `TabSwitcherPanel` (⌃Tab MRU overlay). Native
macOS window tabs removed; ⌘T/⌘W/⇧⌘T/⌘1..9 follow browser conventions; drag & drop covers strip
reorder, tab→pane show/split, cross-window moves, and tear-off. State restoration v2 saves the
tab list + tree of tab indices and migrates the old per-pane snapshot.

### Phase 11 — Visual design system (make the app look exactly like the design artifact) — ✅ shipped

Landed as `Theme.swift` (every color/metric/type token below, one namespace) with the app
pinned to `.darkAqua` (`NSApp.appearance`) and every vibrancy surface (`.titlebar` strip and
pane headers, `.sidebar` rail, `.menu`/`.hudWindow` overlays) replaced by flat Theme fills.
Strip/tabs/pane-chrome/overlays/sidebar match the metrics below; `ThemedTableRowView` gives
every list the amber-tinted selection; tab reorder animates at the 120ms ease behind
`accessibilityDisplayShouldReduceMotion`. Verified offscreen (harness render of the pinned +
two terminals + preview + split scenario — the phase-11 reference render, since removed);
WCAG AA checked:
primary and dim text clear AA on every chrome surface (dim on bar chrome 4.98:1), `textFaint`
(#4C515B, ~2:1) is knowingly sub-AA and reserved for incidental text (line numbers, captions).

The browser-tabs rebuild shipped on stock AppKit colors (`labelColor` alphas, `.titlebar`
vibrancy, `controlAccentColor`). The approved design artifact is the visual contract — a
committed dark chrome with an amber accent — and the app should render it exactly. One
source of truth, then every surface adopts it.

- **`Theme.swift` — the token layer, verbatim from the artifact.** All color/metric/type
  decisions move into one namespace; no component states its own hex or magic padding again.
  - *Chrome*: window/content bg `#17191D`, bar chrome (strip, pane headers, rail) `#1F2228`,
    raised/active surface `#2A2E36`, hover `#262A31`, hairline borders `#34383F`,
    overlay/menu surface `#23262C`.
  - *Text*: primary `#D7DAE0`, dim `#8B909C`, faint (line numbers, captions) `#4C515B`.
  - *Accent*: amber `#D99A3D` — focus borders, visible-tab ticks, switcher selection, drop
    indicators. `controlAccentColor` stops being the accent; semantic session colors are
    separate: busy `#E08A3C`, needs-input `#E5C453` (pulsing), done `#57B36B`,
    failed `#D95757`.
  - *Metrics*: strip 40pt with tabs 34pt bottom-aligned (radius 8 top corners, 2pt gap,
    max 190 / pinned 34), tab icon 14, dot 7; pane header 26pt (icon 12, title 11.5,
    ctx-mono 10); pane corner radius 4, focus border 1pt accent at 70% (not today's 2pt);
    overlay radius 10, menu radius 8, switcher rows 30pt.
  - *Type*: system 12 medium for tab titles (italic = preview), system 11.5 for pane headers,
    monospaced-digit 10–10.5 for ctx% and usage, uppercase letter-spaced mono 9 for overlay
    captions.
- **Committed dark, like the artifact.** The mockup's window is one deliberate dark world, not
  a system-theme chameleon: replace the strip's and pane headers' `NSVisualEffectView
  .titlebar` vibrancy with flat `Theme` fills (`NSAppearance(named: .darkAqua)` pinned on the
  window so system controls — menus, alerts, scrollers — match). Background opacity/blur
  settings keep working: the theme colors take the user's alpha, the behind-window blur stays.
- **Strip restyle to spec.** Active tab reads *raised and connected*: `#2A2E36` fill, top-only
  8pt radius, hairline border that merges into the content edge (no bottom gap). Hover =
  `#262A31`; background tabs flat. Close box only on hover/active with its own hover square;
  the visible-elsewhere tick is a 2pt amber bar inset 10pt; "+" and ⌄ are 24pt hover-squares;
  usage sits far right in mono with the green/amber/red level colors.
- **Pane chrome to spec.** Slim header on bar chrome with the 1pt accent focus border around
  the pane (unfocused: hairline). Default terminal background becomes the chrome bg `#17191D`
  ("Midnight" stays the preset default); viewer/diff/transcript panes adopt the same ground so
  a split window is one surface, not three greys.
- **Overlays and sidebar to spec.** ⌃Tab switcher: `#23262C` panel, radius 10, amber selection
  row with dark text, mono caption. Overflow menu and strip context menus: same surface. The
  sidebar rail, file tree, sessions rows and footer restate their colors from `Theme` (rows
  hover `#262A31`, selection amber-tinted) so the left rail stops looking like a different app.
- **Motion & accessibility.** Keep the artifact's restraint: ~120ms ease for tab reorder/hover,
  the 0.7s needs-input pulse, bell flash — all behind `accessibilityDisplayShouldReduceMotion`.
  Verify every text/ground pair from the token table clears WCAG AA for its size; dim text on
  chrome is the one to watch.
- **Verification.** Extend the offscreen harness to render the artifact's exact scenario
  (pinned + two terminals + preview + split) and eyeball-diff the PNGs against the mockup;
  screenshots land next to the design file so drift is visible in review.

### Phase 12 — Focus discipline + the Chrome tab contract — ✅ shipped

Two intertwined defects in the Phase 10 model, one plan. First, the **multi-focus bug**: more
than one pane can render the amber focus border at once. The border is *pushed* from ~15
scattered sites — become/resignFirstResponder overrides in every content view
(`PaneTerminalView`, viewer, diff, transcript) plus explicit `setFocused` calls in
`TerminalWindowController` (focusPane, dissolvePane, release, movePane, restore) — and AppKit
never calls `resignFirstResponder` on a view that's simply *removed from the hierarchy*
(split-tree surgery, `Pane.display` content swaps; the code already admits this in
`focusPane`). A stale border survives the removal, the next click paints a second one, and
`displayTargetPane()` starts routing strip clicks to the wrong pane — which is also why tabs
stop feeling like Chrome tabs. Second, the **tab contract** was never stated as an invariant,
so behavior drifts per code path.

- **One focused pane, derived — never pushed.** Focus becomes a pure function of
  `window.firstResponder` (KVO-observable): the window controller observes it, resolves the
  responder to its owning pane (the existing `focusedPane()` superview walk), and repaints
  *every* pane idempotently — `pane.setFocused(pane === focused)` — so a second amber border is
  structurally impossible, no matter what tree surgery or content swap just happened.
  `lastFocusedPane`, the window title, and the strip's raised tab all update in that one
  observer. All fifteen push sites die: the responder overrides in the four content views, the
  explicit calls in the controller (those paths just `makeFirstResponder` and let the observer
  repaint), and the `PaneContent` doc-contract line telling contents to report focus.
- **The Chrome/VS Code tab contract, stated and enforced.** (a) A window's default state is
  ONE viewport: opening anything — ⌘T, the strip's "+", openFile/⌘P/search, diff, transcript,
  ⇧⌘T reopen — lands in the focused pane, replacing what it shows, exactly like clicking a
  link in Chrome. No code path may create a pane implicitly. (b) Two-plus tabs are visible
  if and only if the user explicitly split: ⌘D, dragging a tab to a pane edge, or dragging a
  pane header. Closing panes collapses back; the last pane is plain Chrome. (c) Strip click:
  a background tab shows in the focused pane; a tab visible in another pane focuses that pane
  (VS Code editor-group rule — content never jumps between viewports). (d) Exactly one raised
  strip tab, exactly one amber border, always in agreement.
- **"Merge All Panes"** (palette + View menu): collapse the split tree to just the focused
  pane; every displaced tab stays open in the strip as a background tab. The one-keystroke
  way back to the single-viewport default after a review session's worth of splits.
- **Verification.** Offscreen harness renders the killer scenarios — split then drag-show that
  vacates a pane, `display()` swap of a focused pane's tab, close-focused-pane — and asserts
  exactly one focused border and strip agreement afterward; plus a manual click-through.

### Phase 13 — Tab-first screen: "Split Screen" lives on tabs, files accumulate as tabs — ✅ shipped

Phase 12 stated the Chrome contract; this phase finishes retiring the pane vocabulary from the
UX. The main screen *represents the tabs* — one visible by default — and showing a second tab
is something you do **to a tab**, not to a pane. Panes survive only as the internal viewport
mechanism (split tree, drag targets, state restoration all unchanged under the hood).

- **"Split Screen" on the tab** (strip right-click): a background tab's menu gains *Split
  Screen* — the tab appears beside the active one in a new viewport (vertical when the screen
  is wide enough, else horizontal). A tab already visible in a split offers *Unsplit* instead:
  its viewport dissolves and the tab returns to the strip's background, processes untouched.
  Dragging a tab to a screen edge stays as the gesture twin of the menu item.
  **Space divides by the number of screens**: Split Screen and Unsplit rebalance every divider
  by pane count, so two screens are halves, a third makes thirds, and removing one re-spreads
  the space; drag-resized dividers are only rebalanced when the screen count changes.
- **The new-shell-in-a-new-pane commands go away.** ⌘D / ⇧⌘D ("Split Vertically/Horizontally"
  — a *pane* operation that conjured a fresh shell) are removed from the menu, palette, and
  code; the tab-first way to two shells is ⌘T then right-click ▸ Split Screen. The "Panes"
  menu becomes **Screen** and speaks tab language: *Unsplit* (⌥⌘W, was "Close Pane (Keep
  Tab)"), *Unsplit All* (⌃⌘M, was "Merge All Panes"), the ⌥⌘-arrow focus commands.
- **Double-click a file → its own kept tab.** Sidebar tree and Favorites keep single-click =
  preview (the one italic tab, replaced by the next browse); double-click opens the file as a
  *kept* tab, so double-clicking through several files accumulates a tab per file. The
  one-tab-per-path rule still dedupes (double-clicking an open file re-activates it; if it was
  the preview, it's promoted — same as the strip's "Keep Open"). `openFile` grows a `keep:`
  parameter; terminal Cmd-click links and search hits stay preview.
- **Verification.** Harness: Split Screen shows the second tab (two viewports, focus lands on
  it), Unsplit returns to one viewport with the tab backgrounded, keep-opens accumulate
  distinct tabs while preview opens keep replacing one, and the Phase 12 focus invariants
  (exactly one border, strip agreement) hold through all of it.

### Phase 14 — Chrome-parity drag & drop, files as first-class tabs, darker terminal ground — ✅ shipped

Three Chrome/VS Code-parity refinements on the Phase 13 model:

- **Dropping a tab on a screen replaces what it shows.** The old drop geometry made *split*
  the dominant outcome (the replace zone was only the middle 40%×40%). Inverted: a strip tab
  dropped anywhere on a viewport — header included — replaces the shown tab (the displaced
  one backgrounds, processes untouched); only a slim band along each edge (≤ 60pt / 20%)
  still splits the tab out. Strip-drag reordering (insertion caret, pin-boundary aware,
  cross-window adopt, tear-off) already matched browser behavior and stays as is.
- **Files are regular tabs — no preview replacement.** `openFile` (sidebar click, Favorites,
  ⌘P, search hits, terminal Cmd-click links) opens the file in a first-class tab of its own,
  or re-activates it if that path is already open. Opening three files leaves three tabs —
  files never load "one on the other". The preview/Keep-Open machinery stops being produced
  (kept only so tabs restored from older saved state still behave); the sidebar double-click
  wiring from Phase 13 is retired along with it.
- **Terminals ground darker.** New token `Theme.terminalBg` (#0E1013), a step below the
  chrome's #17191D, is the default terminal background — shell output sits in its own deeper
  layer. The "Midnight" preset now maps to it; a new "Slate" preset keeps the Phase 11
  one-surface chrome ground available per pane.

### Phase 15 — Design-artifact fidelity pass (the UI/UX review round) — ✅ shipped

A full-app review against the design artifact (the HTML mockup behind Phase 11 — the visual
contract). The core chrome adopted `Theme.swift` faithfully; this phase closes what the review
found still drifting, finishes the long tail of surfaces the artifact language never reached,
and makes drift *visible* going forward instead of rediscovered by review.

Shipped note: pixel-sampling during implementation showed two review findings ("glaring
minimap strip", "double outline") were largely downscale artifacts of eyeballing full-window
captures — but the underlying token gaps were real and are fixed (minimap viewport now
Theme-tinted; pane containers ground themselves in the chrome color, which also makes
offscreen renders faithful). The rest landed as planned: `design/render-reference.sh` +
`design/reference/main.swift` regenerate the committed `design/phase15-window.png`; the
settings window and the last stock label colors token-ized; rename/new-task prompts moved
onto the overlay panel (`OverlayPrompt.swift`); ⌘D = Split Screen with the MRU background tab
plus a palette picker for a specific tab; AA re-checked — dim text clears 4.5:1 on every
ground (5.96:1 on the darker terminal), `textFaint` stays knowingly sub-AA for incidentals.

Follow-up (15.1): dragging a tab could move the whole window — the strip lived in the
title-bar row (`.fullSizeContentView`), where AppKit's title-bar drag competes with the
strip's own gestures. The strip is now its own row directly *below* a regular title bar
(which owns window dragging and shows the active tab's title); strip-background drags and
double-click-zoom are retired with it, and the traffic-light clearance inset goes away.

Follow-up (15.2): the sidebar's tab picker was still a native `NSSegmentedControl` — aqua
chrome, not the mockup's rail. Replaced with flat hover-square icon buttons
(`RailIconView`): dim SF Symbol on bar chrome, hover fill, amber-tinted selection with the
accent icon tint; tooltips and `UserDefaults` persistence unchanged.

Follow-up (15.3): a **Notes** tab joins the rail — free-text notes the user types directly
(`NotesView`, a plain editable text view; the deliberate exception to viewer-first, since
notes are the user's words, not source files). `NotesStore` owns `~/.suit/notes.txt` with
debounced saves flushed at quit; the terminal's "Create Note from Selection" appends through
the same store, so open Notes tabs in every window update live. Palette: "Show Notes".

Review findings (2026-07-05, offscreen renders vs the phase-11 reference render + token audit):
the minimap column renders as a glaring light strip on the dark ground (`MinimapView` uses
zero Theme tokens); unfocused panes read as a double outline (1pt hairline + the 3pt inset
gap showing the ground through the corner radius) where the artifact shows a single quiet
hairline; the active strip tab should merge into the content edge with no seam;
`SettingsWindowController` is entirely unthemed stock-aqua; `SessionsView`/`SidebarView`
interiors are only partially restated from Theme; every confirmation runs through stock
`NSAlert`; and Split Screen/Unsplit are mouse-only — a "Keyboard-complete" violation. The
Phase 14 darker terminal ground (`terminalBg`) is a deliberate, kept divergence: the reference
render must be updated to match it, not the other way around.

- **Drift harness, committed.** Script the artifact reference scenario (pinned tab + two
  terminals + file viewer + split) as a repeatable offscreen render; regenerate
  `design/phase15-window.png` and commit it whenever chrome changes so visual drift shows up
  in review diffs, not in user reports. Update the reference for the darker terminal ground.
- **Fix the found drifts.** Minimap adopts Theme: chrome ground, syntax blocks from the
  highlighter palette, accent-tinted viewport rectangle, faint markers. Pane outline becomes
  the artifact's single hairline (paint the inset gap in the ground color or drop it; focused
  stays the 1pt amber). Active tab ↔ content edge: remove the seam so the raised tab reads
  connected, per the mockup.
- **Token-complete the long tail.** Settings window rebuilt on the overlay surface language
  (dark fields, amber accents, mono captions — same family as the palette/composer);
  SessionsView rows, sidebar rail/footer, and SearchView controls restate every remaining
  color from Theme; screensaver menus and the rename prompt adopt the overlay style.
- **Dialog language.** Alerts stay native (they render dark under the pinned appearance) but
  get an audit for copy, default-button order, and destructive styling; single-field prompts
  (rename tab, new task name) move onto the palette/composer panel machinery so text entry
  matches the artifact's overlays.
- **Keyboard-complete the tab-first verbs.** Palette entries + bindings for Split Screen
  (with a tab picker when several background tabs exist) and Unsplit, so the Phase 13/14
  model passes the cross-cutting principle without the mouse.
- **Acceptance.** Offscreen renders of every major surface — main window, ⌃Tab switcher,
  palette, composer, settings, strip menus — eyeballed against the artifact; WCAG AA table
  re-checked for the new pairs (dim text on `terminalBg`, settings fields, minimap markers).

### Phase 16 — Diff review comments → batched to Claude — ✅ shipped

Landed as `DiffReview.swift` (the UI-free `DiffReviewComment` + `DiffReviewDraft`: add/update/
remove, one comment per anchored line, and `composePrompt(ref:)` grouping by file in
first-appearance order) plus `DiffPaneContent` additions: `c` on a line in the unified view adds
a comment via the overlay prompt, comments render inline in amber under their line (an amber
`▎` gutter tick), and a header **Review (N)** button opens the inspector menu (Send / Clear, and
per-comment Edit / Open File / Delete). "Send Review to Session…" (the Review menu + the command
palette + `AppDelegate.sendReview(from:)`) composes the draft and pipes it into a chosen Claude
session via Phase 8's `SessionControl.send` (session picker when several are live), then clears
the draft. Comments serialize into the diff tab's `SavedTab.reviewComments`, so a draft survives
a state-restoration round-trip. Verified by a standalone logic test (prompt composition ordering,
one-comment-per-anchor dedup, empty-deletes, Codable round-trip) plus a full `build.sh` + smoke
launch.

Phase 5 opened the review loop (a review set, `n`/`p` walk of every touched file); this closes
it. Today reviewing *then* steering means eyeballing a diff and retyping the feedback into the
session's pane by hand. Turn the diff pane into a real review surface: comment on lines the way
you would on a GitHub PR, then pipe the whole batch into the session as one structured prompt.
Directly serves the review pillar — "verify Claude's work, then tell it what to fix" without a
copy-paste-retype round trip.

- **Line comments in `DiffPaneContent`**: `UnifiedDiffParser` already yields typed `DiffLine`s
  with old/new numbers; a "＋ Comment" affordance (and a keystroke) anchors a note to
  file + line + side. Comments render inline as collapsible threads with an amber gutter tick.
- **Review draft**: comments accumulate into a per-window draft (persisted with state
  restoration). A review inspector lists them all — file, line, text — editable, reorderable,
  deletable.
- **Send to session**: "Send Review to Session…" (palette + a diff-pane button) composes the
  draft into one prompt (`Review of <ref>:` then `<file>:<line> — <comment>` lines) and sends it
  into a chosen Claude session via Phase 8's `SessionControl.send` (bracketed-paste-wrapped,
  session picker when several are live). The draft clears on send.
- **Verification.** Harness renders a diff with comments on several hunks, asserts the composed
  prompt reproduces every file/line/text faithfully and lands in the target pty as one
  bracketed-paste unit, and that the draft survives a state-restoration round-trip.

### Phase 17 — Git blame gutter + file history — ✅ shipped

Understanding before steering. "Who and what last changed this line, and why" is a constant
question when reviewing a monorepo you didn't type. Read-only, so it stays inside the
viewer-first contract — no typing into the buffer, just richer context around it.

- **Blame gutter**: `git blame --porcelain -- <file>` parsed into per-line
  (short-sha, author, date); a toggleable viewer column ("Toggle Blame", palette + keystroke)
  shows sha + author with the full commit subject on hover, tinted by commit age. Sits beside
  the line-number ruler, reusing the gutter plumbing behind `GitChangedLines`.
- **File history**: a "File History" list (Git-tab section + palette "Show File History") of
  commits touching the open file via `git log --follow -- <file>` — sha, subject, author, date;
  click opens that commit's per-file diff in a diff tab (`openGitDiff` extended to a commit ref).
- **Chaining**: clicking a blame line's sha jumps to that commit in the history / opens its diff.
- **Verification.** Harness opens a file with known history, asserts blame lines map to the
  right shas and the history list opens the correct per-file diff; toggling blame off leaves no
  gutter residue.

### Phase 18 — "Set as Goal" from a viewer selection — ✅ shipped

Phase 8 pipes text into sessions; this makes any span of a file a *directive*. Select code or
prose in a viewer, right-click **Set as Goal**, and Suit sends `/goal <selection>` into a chosen
Claude session — turning "this is what I want you to accomplish" into a two-click gesture instead
of copy-paste-retype. The steer-Claude pillar at its most direct.

- **Viewer right-click "Set as Goal"**: `FileViewerPaneContent` already supports
  selection/copy; add a context-menu item (and palette "Set Selection as Claude Goal") enabled
  only with a non-empty selection. Offered the same way on the transcript pane and on terminal
  selections (next to "Send Selection to Claude Session").
- **Sends via `SessionControl`**: composes `/goal ` + the selection and sends it into the target
  session's pty on the Phase 8 send path (bracketed-paste-wrapped so a multi-line selection
  stays one input unit; a trailing `\r` submits). Session picker when several are live; remembers
  the last-targeted session.
- **Provenance framing**: a settings toggle to prepend light context
  (`From <file>:<startLine>-<endLine>:`) so the goal carries where it came from.
- **Verification.** Harness selects a multi-line span in a viewer, invokes the command, asserts
  `/goal` + the exact selection reaches the chosen pty as one bracketed-paste unit; an empty
  selection disables the menu item.

### Phase 19 — Markdown & image/PDF preview tabs — ✅ shipped

Viewer-first, extended past source code. The monorepo has READMEs and design PNGs too — Suit
already renders `design/*.png` in its own workflow — and reviewing them shouldn't mean a trip to
Finder/Preview. All read-only, so no scope creep toward an editor.

- **Markdown preview**: a `MarkdownPaneContent` (or a render mode on the viewer) renders
  `.md`/`.markdown` as formatted read-only text — headings, lists, fenced code (reusing
  `SyntaxHighlighter`), links (Cmd-click → `openFile` for paths, `NSWorkspace` for URLs). A
  toggle flips rendered ↔ raw (raw = today's highlighted viewer).
- **Image tabs**: PNG/JPG/GIF/SVG open in an `ImagePaneContent` — an `NSImageView` with
  zoom-to-fit / actual-size, a checkerboard backing for transparency, pixel dimensions in the
  header.
- **PDF tabs**: a `PDFPaneContent` over PDFKit's `PDFView` — scroll, page thumbnails,
  selection/copy; read-only.
- All three are ordinary tabs — `openFile` routes by extension to the right `PaneContent` — so
  splitting, drag, path-dedupe, and state restoration work unchanged.
- **Verification.** Harness opens a `.md`, a `.png`, and a `.pdf`; asserts each routes to the
  right pane kind, renders, and round-trips through state restoration (path + scroll/zoom).

### Phase 20 — Cross-transcript search — ✅ shipped

Phase 7 shows *one* session's transcript; this makes the whole history queryable — recovering
the context you lose while steering five worktrees at once ("what did Claude do about the auth
bug yesterday").

- **Index**: the transcript JSONL files (`transcript_path` per session, plus historical
  `~/.claude/projects/**/*.jsonl` when present) parsed with the existing `parseTranscriptLine`
  into searchable entries (prompt / assistant text / tool summary), timestamped and
  session-tagged.
- **Search UI**: a palette "Search Transcripts…" / sidebar surface with a query field (reuse
  `RipgrepSearcher` over the JSONL for speed), results grouped by session (name + cwd + date),
  each row a matching snippet.
- **Jump**: click a result → opens the session's `TranscriptPaneContent` anchored to that entry
  (extend the transcript pane with jump-to-offset).
- **Verification.** Harness seeds transcripts with known text, asserts a query returns the right
  entries grouped by session and that clicking anchors the transcript pane to the matching line.

### Phase 21 — Branch / PR overview + gh actions — ✅ shipped

Phase 5 handles worktrees locally; this is the last mile to a merged PR. Once you've reviewed
Claude's changes you shouldn't have to drop into a terminal to ship them — the shipping end of
the review workflow, on the same Git tab that shows the diff.

- **Branch/worktree list**: a "Branches — N" section on the Git tab lists the repo's local
  branches (current first), each with its ahead/behind vs upstream (green ↑ / amber ↓, from
  `%(upstream:track)` in one `git for-each-ref`), a worktree glyph when it's checked out in a
  linked worktree, and an amber dirty dot when that worktree has uncommitted changes; the
  current branch renders in accent with a check icon. Loaded off the main thread and refreshed
  by `GitStatusMonitor`'s ref-watching. Clicking a branch checks it out (or switches the sidebar
  to its worktree when git can't). See `GitBranches.swift` (`GitBranchList`) + `GitView.swift`.
- **gh actions**: per-branch right-click menu — "Create PR…" (`gh pr create`, title prefilled
  from the branch, body auto-filled from the branch's commit subjects), "Open on GitHub"
  (`gh pr view --web`, or the compare page when no PR exists yet), and "Checkout". gh is
  resolved from the known Homebrew/system install paths (a GUI app's PATH doesn't include them)
  and pointed at the repo by working directory (`gh` has no `-C`). Degrades gracefully: without
  gh the menu shows a disabled "Install the gh CLI…" hint and Checkout still works; every gh
  failure (no remote, not authed, unpushed branch) surfaces gh's own message in an alert.
- **PR status**: when `gh` lists a PR for a branch (`gh pr list --json …statusCheckRollup`), the
  row shows a `#<number>` badge colored by state (open / merged / closed) with a ✓/✕/• check
  rollup glyph; loaded in a second background pass so the branch list never waits on the network.
- **Verification.** Offscreen harness against a fixture repo with ahead / behind / diverged
  branches, a dirty worktree, and the current branch asserts the counts, dirty dots, worktree
  glyph, and current-branch highlight all render correctly; gh actions no-op / surface a clean
  error when no GitHub remote is configured.

### Phase 22 — file:line bookmarks — ✅ shipped

Landed as `Bookmarks.swift` (the `Bookmark` value + `BookmarksStore`, a `~/.suit/bookmarks.json`
singleton mirroring NotesStore — `$HOME`-first, `didUpdate`, dead paths pruned on load — plus the
`BookmarksView` sidebar tab) and viewer/rail wiring: a new `.bookmarks` rail case (bookmark SF
Symbol), a gutter click or ⇧⌘L / "Toggle Bookmark" (palette + Edit menu + viewer context menu)
toggles the caret's `file:line`, an accent tick draws on the gutter's left edge and the minimap,
and the Bookmarks tab lists them (Enter / double-click opens via `openFile(atPath:line:)`,
right-click renames/removes). Verified by a standalone logic test that links the real store
(toggle add/remove, snippet trim, `lines(inFile:)`, rename, dead-path prune-on-load, cross-instance
persistence) plus a full `build.sh` + smoke launch.

Phase 9 favorites pin *files*; a review or refactor lives at *specific lines*. Lightweight,
high-leverage navigation for holding several threads of a change in your head at once —
"jump back to the three places I'm tracking."

- **Set/clear**: a viewer gutter click / "Toggle Bookmark" (palette + keystroke) pins the
  current `file:line` with an optional name; a tick shows in the gutter and on the minimap
  (`MinimapView` already renders `Marker` ticks).
- **Bookmarks list**: a sidebar rail tab (one more enum case + SF Symbol, per the Phase 9
  pattern) listing bookmarks — name, `file:line`, snippet — keyboard-navigable; Enter opens the
  file at that line (`openFile(atPath:line:)`). Right-click removes/renames.
- **Persistence**: `~/.suit/bookmarks.json` (path resolves `$HOME` first, like Notes/Favorites),
  shared across windows via a `didUpdate` store; dead paths pruned on load.
- **Verification.** Harness sets bookmarks across files, asserts the list opens each at the right
  line and that ticks appear in gutter + minimap; a moved/deleted file's bookmark is pruned.

### Phase 23 — Usage & cost analytics — 🚧 in progress (worktree-phase-23-usage-cost-analytics, 2026-07-07)

Phases 4 and 7 already collect `cost_usd` and context/usage into the session files; this makes it
legible. Steering a fleet of sessions means watching spend — a global rate-limit bar isn't the
same as "this task cost $4 and isn't done, and which session is the runaway."

- **Data**: accumulate a lightweight time series (append-only `~/.suit/usage-history.jsonl`
  written on session updates) so history survives the session-file pruning `ClaudeSessionMonitor`
  does.
- **Panel**: an analytics surface (palette "Show Usage Analytics" / a footer expansion) charting
  cost and tokens per session and per task (worktree/task name) over time — bars/sparklines via a
  small custom `NSView` (no external chart dependency, per the no-SwiftPM constraint), color-coded
  by `Theme.usageLevelColor`.
- **Rollups**: the 5h and weekly windows already surface globally; add per-task subtotals ("this
  task cost $X across N sessions") and a "runaway" highlight for the costliest active session.
- **Verification.** Harness seeds `usage-history` with known values, asserts per-session and
  per-task rollups and the chart totals match; the history file round-trips and survives a
  session-file cleanup.

### Phase 24 — "What changed while I was away" marker — 🚧 in progress (worktree-phase-24-away-marker, 2026-07-07)

The async-delegation review. You start sessions, step away, and come back wanting *one* diff of
everything that moved across the fleet — not to re-inspect each worktree. Directly serves "verify
Claude's work faster" for the multi-session workflow Phase 5 set up.

- **Drop a marker**: a "Mark Now" command (palette + a Git-tab button) records a per-repo
  checkpoint — HEAD sha per worktree plus a timestamp — into `~/.suit/markers.json`.
- **Catch-up diff**: "What Changed Since Mark" composes an aggregate diff across all of the
  repo's worktrees (`git diff <marker-sha>..` per worktree, plus uncommitted working-tree
  changes) into a single review set — the Phase 5 review machinery (diff tabs, `n`/`p` walk) fed
  a multi-worktree changed-file list.
- **Summary header**: files-touched / insertions / deletions per worktree, and which Claude
  session (by cwd match) produced each, so the catch-up reads as "session X changed these 6
  files."
- **Verification.** Harness marks, makes commits + uncommitted edits across two worktrees, then
  asserts the catch-up review set lists exactly the changed files with correct per-worktree
  attribution.

### Phase 25 — Visual checkpoint / rewind timeline — ✅ shipped

Claude Code auto-saves a code checkpoint before each change (`/rewind`, Esc-Esc restores code /
conversation / both). Today you rewind blind by typing into the pty; this makes the checkpoint
history a *thing you read and scrub* — squarely viewer-first, and it lets you undo a bad Claude
turn without `git stash` gymnastics, so you can let Claude run more freely and still verify/roll
back fast.

- **Timeline pane** (`CheckpointTimelinePaneContent`): a read-only viewer tab rendering a
  session's checkpoints as a vertical commit-graph — each node timestamped with its triggering
  prompt summary and touched-files/±lines, forks branching off. Live-tails as new checkpoints
  land, like `TranscriptPaneContent`. Opened from a session row / palette ("Open Checkpoint
  Timeline…"), one per window, reused like the transcript pane.
- **Restore controls**: the selected node exposes *Restore code* / *Restore conversation* /
  *Restore both* and *Fork from here*, driven over the pty on the Phase 8 `SessionControl.send`
  path (inject `/rewind` with the checkpoint ref, or the fork command). Destructive restores
  confirm first (native alert, per Phase 15 dialog language).
- **Source of truth**: read checkpoint state from whatever Claude Code exposes to a pty-driven
  app — the hook/statusline `~/.suit/sessions/<id>.json` pipeline first, falling back to any
  on-disk checkpoint store; degrade gracefully to "no checkpoints" when the running Claude Code
  version predates the feature or exposes nothing machine-readable (see the open question below).
- **Verification.** Harness seeds a session with a known checkpoint sequence (incl. a fork),
  asserts the timeline renders the right nodes/edges in order, that selecting a node and invoking
  each restore composes the correct `/rewind` payload into the target pty as one bracketed-paste
  unit, and that the pane round-trips through state restoration.
- **Open question to resolve first**: whether checkpoint/rewind history is readable by a
  pty-driven app at all (files / hook events) or is interactive-terminal-only — spike this before
  committing to the timeline; if unreadable, the phase narrows to a `/rewind` launcher.

### Phase 26 — Plan / Agent / Ask mode toggle + plan-approval pane — 🚧 in progress (worktree-phase-26-mode-toggle, 2026-07-07)

Claude Code's Plan Mode is a read-only phase that maps the codebase and proposes a structured
plan before touching a file; today it hides behind Shift+Tab cycling. Surfacing the mode as a
visible control and rendering the plan as an *approvable* artifact is the steer pillar at its
sharpest — you approve the plan, then edits run, and you never wonder which invisible mode a pane
is in.

- **Mode control**: a segmented Ask · Plan · Agent control in the pane title bar (and palette
  entries + a keystroke) for the focused Claude tab, injecting the mode switch over the pty; the
  current mode reads back from the session JSON when available, else reflects the last command
  Suit sent. Purely a control surface — no Claude-side changes.
- **Plan-approval pane**: when a plan arrives (parsed from the transcript / session file), render
  it read-only as numbered steps in a review surface with *Approve & run* / *Edit* / *Discard*,
  each dispatching over `SessionControl.send`. Reuses the transcript-parsing plumbing.
- **Fits viewer-first**: the plan is something you *read and accept*, not type; the mode control
  makes the read/act boundary explicit.
- **Verification.** Harness feeds a session a Plan-Mode plan, asserts the pane renders every step
  in order, that Approve/Edit/Discard inject the correct payload into the pty, and that the mode
  control reflects and switches mode correctly (readback + send).

### Phase 27 — Live slash-command menu + one-tap context controls 🚧 in progress (worktree-phase-27-slash-command-menu, 2026-07-07)

The context-window meter (Phase 7) tells you *when* to `/compact`; this makes acting on it one
tap instead of a typed incantation, and turns every built-in, custom, and skill command into a
discoverable button. Directly steer-faster: the terminal's hidden verbs become native chrome.

- **Context bar action**: the pane title bar's context-% meter gains a one-tap `/compact`
  (amber past the Phase 7 threshold), injected over the pty.
- **Command menu**: a palette-style menu of available commands — built-ins (`/context`,
  `/clear`, `/usage`, `/compact`), custom `~/.claude/commands/*.md`, and skills — that dispatch
  into the focused Claude tab via `SessionControl.send`. The list is read from the session's
  init/state (SDK `slash_commands` when exposed) or scanned from the command/skill dirs, so it
  stays accurate. Complements the Phase 8 prompt library.
- **Keyboard-complete**: every command reachable from the palette; the context bar action has a
  binding.
- **Verification.** Harness asserts the menu lists the discovered commands (built-in + a seeded
  custom command + a seeded skill), that selecting one injects the exact command string into the
  target pty, and that the `/compact` bar action fires on the focused session.

### Phase 28 — Fleet-supervision dashboard (all sessions at a glance) 🚧 in progress (worktree-phase-28-fleet-dashboard, 2026-07-07)

Suit signals per-window session state (tab dots, title-bar meters) but has no cross-window view
of the whole fleet — the biggest gap in the "orchestrate multiple sessions" pillar. This is the
one surface that answers "who needs me right now" across every window without hunting through
tabs.

- **Sessions dashboard** (a window-spanning panel + palette "Show Fleet"): every live Claude
  session as a row — status dot (busy / needs-input / done / failed), project, worktree/branch,
  current-task summary, context %, cost — fed by `ClaudeSessionMonitor` across all windows,
  sorted **needs-you-first**. Reuses the session model and `Theme` row styling.
- **Actions per row**: Focus (activate the window + pane via `AppDelegate.focusSession`),
  Interrupt (Esc over the pty), Continue, Archive/Stop. Answers route through the Phase 8 send
  path.
- **Optional Kanban view**: a board where one card = one worktree = one agent (To-do / Running /
  Needs-you / Done columns), the Vibe-Kanban model, as an alternate layout of the same data.
- **Verification.** Harness seeds several sessions across windows in mixed states, asserts the
  dashboard lists them sorted needs-you-first with correct fields, that Focus resolves to the
  right pane, and that row actions inject the right payloads.

### Phase 29 — Automated feedback-loop routing (CI / PR / conflicts → the right session) — 🚧 in progress (worktree-phase-29-feedback-routing, 2026-07-07)

Phase 16 batches *your* review comments to a session; this closes the loop on *machine* feedback.
When CI fails, a reviewer leaves PR comments, or a merge conflicts, the fix belongs in the exact
session that wrote the change — routing it there by hand is the slow part of steering a fleet.

- **Feedback inbox** (Git-tab section + palette): watches CI status (`gh run` / checks), PR review
  comments (`gh pr view --json`), and merge-conflict state per worktree, listing each event with
  its logs/diff and the **originating session** resolved via the existing pid/cwd session map.
- **One-tap route**: "Route to session" composes the failure log / review comments / conflict
  markers into a structured prompt and injects it into that session's pty (Phase 8 send,
  bracketed-paste), with a session picker when attribution is ambiguous.
- **Reviewer-agent lane (optional)**: kick a dedicated review pass (a fresh `claude` in the
  worktree with a review prompt) and surface its status inline.
- **Caveat**: routing is opt-in and only as reliable as the session↔worktree attribution;
  ambiguous matches always fall back to a picker rather than guessing.
- **Verification.** Harness simulates a failed check / a PR comment / a conflict against known
  worktrees, asserts each is attributed to the correct session and that Route injects the composed
  prompt into the right pty as one unit; ambiguous attribution surfaces a picker.

### Phase 30 — Background-task monitor (dev servers · tests · builds)

Claude Code backgrounds long-running processes (Ctrl+B) and tails them via BashOutput; from
Suit's side those processes are invisible until you scroll the shell. Making them tracked panes
lets you verify process health — "did the dev server come up, are the tests green" — without
blocking the agent or spelunking scrollback.

- **Task monitor pane**: lists background processes spawned from a pane's shell — command, status
  (running / exited-clean / failed), port when detectable, and an incremental log tail — reusing
  the DispatchSource file-tailing behind `TranscriptPaneContent`. Discovered from the pane's child
  process tree (the `ProcessUtil`/sysctl plumbing already used for session assignment) and any
  Claude Code background-task record exposed in the session files.
- **Surfacing**: a failed background task pulses its pane's strip item (like a bell) and shows in
  the pane header; the monitor opens from the palette / a pane action.
- **Verification.** Harness starts known background processes (one long-lived, one that exits
  clean, one that fails), asserts the monitor lists each with correct status/port and tails new
  log lines, and that a failure raises the strip-item attention signal.

### Phase 31 — Per-session worktree isolation choice + subagent tree

Phase 5 made "New task" always spin a worktree; this makes isolation an explicit per-session
*choice* and renders nested subagent worktrees (Claude Code's `isolation: worktree` subagents,
auto-removed when they finish clean) as a tree, so a session that fans out into sub-agents stays
legible instead of scattering anonymous checkouts.

- **Isolation toggle**: the "New task" prompt (`OverlayPrompt`) gains an "Isolate in worktree"
  switch — on reproduces today's behavior, off runs `claude` in the current checkout — so cheap
  tasks skip the worktree churn. Persisted default in settings.
- **Subagent tree**: the fleet dashboard / Git tab renders a session's `isolation: worktree`
  subagents nested under it (name, worktree path, status), discovered from the worktree list +
  session map, pruned as Claude Code auto-removes finished ones. Interoperates with — doesn't
  fight — `WorktreeTasks` cleanup.
- **Verification.** Harness creates a task with isolation on and off (asserts the right checkout
  is used), seeds a session with two subagent worktrees, asserts they render nested under the
  parent and disappear from the tree when their worktrees are removed.

### Phase 32 — Autopilot (autonomous roadmap execution) — ✅ shipped

Landed as `AutopilotEngine.swift` (the main-queue state machine ticked from AppDelegate's 3 s
timer — preflight → spawn → completion verification → gates → merge → cleanup — plus relaunch
adoption that re-resolves a persisted run against worktree/PR reality), `AutopilotScheduler.swift`
(pure budget math), `RoadmapParser.swift` (this file as the input), `AutopilotGates.swift`
(build.sh + headless-review runners), `AutopilotPrompts.swift` (worker / nudge / rejection /
conflict prompts) and `AutopilotStore.swift` (`~/.suit/autopilot/` persistence), with plumbing
extensions: `GitHubCLI` merge/PR-state/auth calls + `SUIT_GH_PATH`, `ClaudeUsage` `resets_at`
parsing + an ungated snapshot reader, `WorktreeTasks.removeAfterRemoteMerge`, and
`SessionControl.send(submitDelay:)`.

Use every bit of the Claude Code token limits autonomously. Whenever budget allows, Suit spins
up a Claude session that implements the next unshipped phase of this file end-to-end —
worktree → implementation → build → README → ✅ heading mark → commit → push → PR — then the
app gates and auto-merges the PR and loops to the next phase. One run at a time; the user
steers only by editing ROADMAP.md.

- **Scheduler + modes**: `AutopilotScheduler.mayStartRun` gates run *starts* (an in-flight run
  always finishes) on the statusline's usage snapshot — `resets_at` now parsed, a percentage
  past its reset counts as zero, and the model-scoped weekly can bind before the global one.
  Three user-switchable modes — *Pace to reset* (spend the weekly window evenly toward a target
  %), *Max out* (run whenever under the ceilings), *Night shift* (max-out inside configurable
  hours, midnight wrap) — under hard 5h/weekly ceilings, all in the Settings "Autopilot"
  section along with project root, gate attempts, stall minutes, extra claude args, review
  model, and a keep-the-Mac-awake toggle held across runs.
- **Worker contract**: after preflight (gh installed + authed, main checkout on a clean
  up-to-date default branch, no leftover task worktree), the engine creates the task worktree
  (`WorktreeTasks.createTask`), opens a visible `⚙ Phase <N> — <Title>` terminal tab running
  `claude --dangerously-skip-permissions` (never focus-stealing), and — once the session file
  appears and is pinned to the run — sends the worker prompt with the phase spec embedded
  verbatim (snapshotted at spawn, immune to concurrent roadmap edits). Session `done` only
  *triggers* verification — the Stop hook fires at every turn end, so world state is the truth:
  commits ahead of default, branch pushed, PR open with the `Autopilot-Phase` trailer, worktree
  clean, heading marked ✅. Misses nudge the live session with the specific gaps (capped,
  spaced); dead-worker respawn with `--continue` and a wall-clock watchdog back it up.
- **Review gate + merge**: the build gate runs first (`build.sh` in the worktree, log captured,
  timeout), then a headless `claude -p` reviewer judges CLAUDE.md rules + the spec snapshot +
  the full PR diff and must answer `VERDICT: APPROVE|REJECT` alone on the final line — never
  auto-approve on ambiguity. Failures feed the build-log tail / numbered findings back into the
  live session (attempts capped, phase blocked past the cap); approve → `gh pr merge --merge`,
  confirmed `MERGED`, main fast-forwarded, worktree + branch removed, history appended,
  notification posted, run tab closed, loop.
- **Steering conventions** (also stated in the preamble above): priority = document order,
  `✅` in a heading = shipped, `⏸` = skipped; re-parsed at every scheduling decision; the one
  sanctioned engine write to this file is `Skip Current Phase` appending `⏸`. Roadmap drift
  (already-implemented but unmarked phases) resolves as cheap docs-only PRs via the worker
  prompt's drift clause.
- **UI surfaces**: an Autopilot row in the sidebar footer (state · phase · next-run ETA;
  click → run tab while running, log otherwise), palette verbs — Enable/Disable, Run Next Phase
  Now, Pause After Current Run/Resume, Retry, Skip Current Phase, Show Log, Open Run Tab
  (palette-reachable = keyboard-complete; no new bindings) — and notifications for merged /
  blocked / all-phases-done with click-through to the run tab or log.
- **Observability**: everything under `~/.suit/autopilot/` — `state.json` (the current run,
  rewritten on every stage transition; the relaunch-adoption input), `history.jsonl` (one row
  per finished run: outcome, PR, attempts, cost), `autopilot.log` (human-readable event lines;
  "Show Log" opens it as a viewer tab), and `logs/<slug>/build-N.log` / `review-N.log`.
- **Verification.** Standalone logic tests (sandboxed `$HOME`): parser fixtures (`✅ shipped`
  with/without parentheticals, `⏸`, malformed headings, all-shipped → nil, spec body stops at
  the next heading), scheduler math (pace at 0/50/100% elapsed, ceilings, hard stop, night
  wrap across midnight, stale/missing snapshots, `resets_at` epoch + ISO forms, model-weekly
  binding), prompt composition (verbatim spec, exact trailer lines, diff-truncation header),
  verdict parsing (final-line rule, verdict-shaped text mid-output ignored, garbage never
  approves), the adoption truth table, and a store round-trip. A pipeline harness drives a
  fixture repo with fake `claude`/`gh` (injected via `SUIT_CLAUDE_PATH`/`SUIT_GH_PATH`) through
  spawn → nudge → reject → approve → merge → cleanup, asserting the merge argv, worktree/branch
  removal, the history row, and `⏸` honored on the next pass; plus full `./build.sh` and a
  manual smoke of the footer row, run tab, and notification click-throughs.

## Cross-cutting principles ("works for the user")

- **Keyboard-complete**: every action has a binding and a palette entry; the mouse is optional.
- **Panes are cheap and disposable**: contents open as first-class tabs (deduped by path for
  files) — and `⌘W` closes anything (tab first, then window).
- **State restoration** — ✅ shipped: reopen with the same layout, files, scroll positions, and
  worktree panes (extends the existing cwd persistence; see `StateRestoration.swift`. Terminals
  restore as fresh shells in their old cwd; native window-tab grouping isn't preserved).
- **No modes, no dialogs where a pane will do**; the app never steals focus from the pane you're
  typing in — attention is *signaled* (badges, pulses), never *forced*.
- **Performance floor**: fuzzy-open < 50ms, search-first-result < 100ms; the FSEvents-backed
  file index makes both trivial at monorepo scale.

## Risk notes

- **Tree-sitter grammars** are the only nontrivial vendoring job (each grammar is a big
  generated `parser.c`) — but it's C, so it sidesteps the SwiftPM problem entirely. Fallback if
  it drags: ship Phase 3 with a regex-based highlighter for the top 4 languages, swap later.
- **Session detection** depends on Claude Code hook/statusline stability — but both ends are
  controlled here, and the JSON-file handshake degrades gracefully (no file → pane is just a
  terminal).
- **Scope creep toward "editor"**: the viewer will tempt. Hold the line: selection+copy and
  jump-to yes; typing into the buffer no.

## First move

Phase 0 + the fuzzy opener from Phase 1 in one worktree — the smallest slice that changes daily
usage.
