# Suit Roadmap

Expanding Suit from a terminal app into a **native macOS cockpit for driving Claude Code across a
codebase** — you navigate, review, and orchestrate; Claude writes.

## Product thesis

Not an IDE. An IDE assumes *you* type the code; Suit assumes *Claude* does, so the app optimizes
for the human's real jobs: **finding, reading, reviewing, and directing sessions.** Every feature
must pass the test: "does this help me steer Claude or verify its work faster?"

Settled decisions:

- **Viewer-first, not editor.** Rich read-only file viewing (highlighting, minimap, diffs,
  jump-to-line). The one sanctioned write slice is the autosave-guarded editable viewer (Phase 37);
  everything beyond it (refactors, project-wide rename, an editor UI) is Claude's job.
- **Native AppKit UI.** Browser, search, viewer, minimap are NSViews in the split tree / sidebar —
  not TUI panes. Heavy non-UI logic may move to a Go sidecar later if it grows.
- **Claude-first across four pillars**: session awareness, review workflow, codebase navigation,
  multi-session orchestration.

## Architecture

- **Swift/AppKit is the product layer** (no longer "kept minimal").
- **`PaneContent` protocol** lets the split tree / title bars / focus / drag host any pane kind
  (terminal, viewer, diff, search, …) — the load-bearing early refactor. Phase 10 then made a
  window-level **browser tab strip** own every open thing, with split-tree panes as viewports.
- Plus a collapsible **sidebar** (Files / Git / SSH / Notes / …) outside the split tree.

## Steering conventions (Autopilot)

Since Phase 32 this file is **Autopilot's steering interface**, re-parsed at every scheduling
decision. **Priority = document order** (reordering phases is the priority UI). In a
`### Phase N — Title` heading: `✅` anywhere = shipped, `⏸` = skipped, `🚧` = claimed/in progress;
the first phase with none of these is the eligible one. A running worker holds a snapshot of its
phase's spec taken at spawn, so mid-run edits only affect the next decision.

## Phases

### Phase 0 — Foundations (enables everything else) — ✅ shipped

`PaneContent` protocol refactor; collapsible tabbed sidebar (⌘B); command palette (⌘K) as the
"everything reachable by keyboard" backbone every later feature registers into.

### Phase 1 — Navigate (file browser + fuzzy open + viewer) — ✅ shipped

FSEvents-driven, `.gitignore`-aware file browser with sub-project detection; fuzzy opener (⌘P);
read-only viewer pane (line numbers, ⌘G go-to-line); clickable `path:line` links in terminal
output → viewer at that line.

### Phase 2 — Search — ✅ shipped

Bundled `rg --json` engine; live grouped results sidebar (⌘⇧F) with regex/case/glob toggles and
repo / sub-project / pane-cwd scope; in-file search (⌘F).

### Phase 3 — Read well (highlighting, minimap, diffs) — ✅ shipped

Syntax highlighting (regex-based scanner; tree-sitter still an open swap-in), a document minimap
with overlay markers, and unified / side-by-side diff panes driven by `git diff`.

### Phase 4 — Claude session awareness — ✅ shipped

Claude Code hooks + statusline write `~/.suit/sessions/<id>.json` (state/cwd/task/usage); panes
map to sessions by pid/cwd; attention shows in pane chrome; global usage bars render natively.
(Hook wiring is a manual install step — see `scripts/claude/`.)

### Phase 5 — Review workflow + orchestration — ✅ shipped

Git status badges everywhere; one-keystroke review set (diff panes for a session's touched files,
`n`/`p` walk); worktree orchestration — "New task" spins a worktree + `claude` pane, finish
merges/removes from the UI.

### Phase 6 — Tabbed panes (decouple "open" from "visible") — ✅ shipped

Adopted the VS Code editor-group model: a split leaf hosts a tabbed set of contents. Superseded by
the Phase 10 browser-tabs rebuild; state restoration followed up.

### Phase 7 — See what Claude is doing (transcript, context, escalation) — ✅ shipped

Richer session files (transcript path, context %, cost); a live-tailing read-only transcript pane;
a per-pane context-fill meter; native needs-input notifications + Dock badge (never steals focus).

### Phase 8 — Talk back (steer sessions without touching their panes) — ✅ shipped

Writes into a claude pane's pty (`SessionControl.send`, bracketed-paste): session quick actions, a
floating prompt composer with `@`-file-completion, "Send Selection to Claude Session", and a
`~/.suit/prompts/*.md` prompt library surfaced in the palette.

### Phase 9 — Sidebar rail: icon tabs, explicit folder scope, favorites — ✅ shipped

Segmented sidebar tabs replaced by an SF-Symbol icon rail; a "Select Folder…" that pins the
browser/search root; a favorites + recents surface backed by `~/.suit/favorites.json`.

### Phase 10 — Browser tabs (one strip owns every open thing) — ✅ shipped

A single window-level tab strip owns every tab (terminal/viewer/diff/transcript); split-tree panes
are viewports showing a subset. `TabStore` (+ MRU + reopen), `TabStripView`, `TabSwitcherPanel`
(⌃Tab). Native macOS window tabs removed; ⌘T/⌘W/⇧⌘T/⌘1..9 follow browser conventions; drag & drop
covers reorder, show/split, cross-window move, and tear-off. State restoration v2.

### Phase 11 — Visual design system (make the app look like the design artifact) — ✅ shipped

`Theme.swift` — every color/metric/type token in one namespace, pinned `.darkAqua`, vibrancy
replaced by flat Theme fills; strip/tabs/pane chrome/overlays/sidebar restyled to spec; amber
accent; motion behind reduce-motion; WCAG AA checked (`textFaint` knowingly sub-AA for incidentals).

### Phase 12 — Focus discipline + the Chrome tab contract — ✅ shipped

Focus became a pure function of `window.firstResponder` (KVO-observed, repaint every pane
idempotently) — killing the multi-focus bug and the ~15 push sites. Stated and enforced the
Chrome/VS Code tab contract (one viewport default; splits only on explicit user action; one raised
tab = one amber border). Added "Merge All Panes".

### Phase 13 — Tab-first screen: "Split Screen" lives on tabs — ✅ shipped

Split Screen / Unsplit are tab operations (strip right-click, drag-to-edge), rebalancing dividers
by pane count; the old new-shell-in-a-new-pane ⌘D/⇧⌘D pane commands removed; the "Panes" menu
became "Screen"; double-click a file opened it as a kept tab.

### Phase 14 — Chrome-parity drag & drop, files as first-class tabs, darker terminal ground — ✅ shipped

A tab dropped anywhere on a viewport replaces the shown tab (only slim edges split); files always
open as their own deduped tab (no preview replacement); terminals ground darker (`Theme.terminalBg`
#0E1013, the "Midnight" default; "Slate" keeps the one-surface chrome ground).

### Phase 15 — Design-artifact fidelity pass (the UI/UX review round) — ✅ shipped

Closed the review's drift findings: minimap Theme-tinted, single pane hairline, seamless active
tab; a committed offscreen reference render (`design/render-reference.sh` → `phase15-window.png`);
token-completed settings/sidebar/search; single-field prompts moved onto the overlay panel; keyboard
verbs for Split Screen/Unsplit. Follow-ups: strip moved below a real title bar (15.1), icon rail
(15.2), Notes tab (15.3).

### Phase 16 — Diff review comments → batched to Claude — ✅ shipped

`DiffReview.swift` — GitHub-PR-style line comments in the diff pane (amber inline threads + gutter
tick), a review draft (persisted with state restoration), and "Send Review to Session…" composing
the batch into one prompt piped to a chosen session.

### Phase 17 — Git blame gutter + file history — ✅ shipped

`git blame --porcelain` per-line gutter (age-tinted sha + author, subject on hover, toggleable); a
"File History" list from `git log --follow`; clicking a commit / blame sha opens its per-file diff.

### Phase 18 — "Set as Goal" from a viewer selection — ✅ shipped

Select code/prose → right-click "Set as Goal" sends `/goal <selection>` into a chosen session
(bracketed-paste); optional provenance framing (`From <file>:<lines>:`); offered on viewer,
transcript, and terminal selections.

### Phase 19 — Markdown & image/PDF preview tabs — ✅ shipped

`openFile` routes by extension: rendered Markdown (rendered ↔ raw toggle), images (`NSImageView`,
zoom, checkerboard), and PDFs (PDFKit) as ordinary tabs, so split/drag/dedupe/restoration work
unchanged.

### Phase 20 — Cross-transcript search — ✅ shipped

Index the transcript JSONL files (+ historical `~/.claude/projects/**/*.jsonl`); a "Search
Transcripts…" surface (rg over JSONL) grouped by session; clicking anchors the transcript pane to
the matching entry.

### Phase 21 — Branch / PR overview + gh actions — ✅ shipped

Git-tab "Branches — N" section (ahead/behind, worktree glyph, dirty dot, current in accent);
per-branch gh actions (Create PR… / Open on GitHub / Checkout); `#N` PR badge + check-rollup glyph.
Degrades gracefully without gh. See `GitBranches.swift`.

### Phase 22 — file:line bookmarks — ✅ shipped

`Bookmarks.swift` + a `.bookmarks` rail tab: gutter click / ⇧⌘L toggles a `file:line` bookmark
(gutter + minimap tick), the list opens each at its line, backed by `~/.suit/bookmarks.json` with
dead-path pruning.

### Phase 23 — Usage & cost analytics — 🚧 in progress (worktree-phase-23-usage-cost-analytics, 2026-07-07)

Make the collected `cost_usd`/context/usage legible: an append-only `~/.suit/usage-history.jsonl`
time series; an analytics panel charting cost/tokens per session and per task via a small custom
NSView; per-task rollups and a runaway-session highlight.

### Phase 24 — "What changed while I was away" marker — ✅ shipped

"Mark Now" records a per-repo HEAD-per-worktree checkpoint into `~/.suit/markers.json`; "What
Changed Since Mark" composes an aggregate multi-worktree review set (diff vs marker + uncommitted),
with a per-worktree files/±lines summary attributed to the producing session.

### Phase 25 — Visual checkpoint / rewind timeline — ✅ shipped

A read-only timeline pane of a session's Claude Code checkpoints (live-tailed), with Restore
code/conversation/both and Fork-from-here dispatched over the pty; degrades to "no checkpoints"
when the running Claude Code exposes nothing machine-readable.

### Phase 26 — Plan / Agent / Ask mode toggle + plan-approval pane — ✅ shipped

`ClaudeMode.swift` / `PlanParsing.swift` — palette Ask/Plan/Agent mode switch over the pty (readback
from session JSON, else last-sent); a plan-approval pane rendering the latest `ExitPlanMode` plan as
numbered steps with Approve & Run / Edit / Discard.

### Phase 27 — Live slash-command menu + one-tap context controls — ✅ shipped

A one-tap `/compact` on the context meter; a palette-style menu of available commands (built-ins +
`~/.claude/commands/*.md` + skills, read from session init or the dirs) dispatched into the focused
Claude tab.

### Phase 28 — Fleet-supervision dashboard (all sessions at a glance) — ✅ shipped

A window-spanning "Fleet" panel: every live session as a row (status/project/worktree/task/context/
cost) across all windows, sorted needs-you-first, with Focus/Interrupt/Continue/Stop row actions;
optional Kanban view.

### Phase 29 — Automated feedback-loop routing (CI / PR / conflicts → the right session) — ✅ shipped

`FeedbackRouting.swift` / `FeedbackInbox.swift` — a Git-tab inbox of CI failures, PR review
comments, and merge conflicts per worktree, each attributed to its originating session (picker when
ambiguous); one-tap route composes the detail into a prompt; an optional reviewer-agent lane.

### Phase 30 — Background-task monitor (dev servers · tests · builds) — ✅ shipped

A task-monitor pane listing a shell's background processes (command/status/port/log tail, discovered
via the process tree + session files); a failed task pulses its strip item and shows in the header.

### Phase 31 — Per-session worktree isolation choice + subagent tree — ✅ shipped

`TaskLaunch.swift` / `SubagentTree.swift` — an "Isolate in worktree" toggle on the New-task prompt
(persisted default); the fleet/Git tab renders `isolation: worktree` subagents nested under their
session, pruned as Claude Code auto-removes them.

### Phase 32 — Autopilot (autonomous roadmap execution) — ✅ shipped

`AutopilotEngine.swift` + scheduler/parser/gates/prompts/store: whenever budget allows, spins a
`claude` session to implement the next unshipped phase end-to-end (worktree → implementation → build
→ ✅ mark → commit → push → PR), then the app build-gates, headless-review-gates, auto-merges the PR,
and loops. Budget modes (Pace to reset / Max out / Night shift) under 5h/weekly ceilings; world-state
verification (not the Stop hook); relaunch adoption; sidebar row + palette verbs + notifications;
everything under `~/.suit/autopilot/`. The user steers only by editing this file.

### Phase 33 — Go-to-definition & find-references — ✅ shipped

`SymbolIndex*.swift` — a bundled `universal-ctags` index per git root (FSEvents-refreshed, off-main);
Cmd-click / keystroke go-to-definition (picker for several); a references pane reusing the search
result view (ctags + rg word search). Degrades to an rg fallback when ctags is missing.

### Phase 34 — Commit graph pane — ✅ shipped

`CommitGraph*.swift` — a read-only pane rendering the `git log --all` DAG as a custom NSView (lanes,
edges, age-tinted nodes, ref badges); click a node → its diff; virtualizes large histories; refreshed
by `GitStatusMonitor`.

### Phase 35 — Broadcast input to multiple sessions — ✅ shipped

Fleet-row multi-select + a broadcast composer: "Broadcast to Selected / All Live" loops
`SessionControl.send` over each target pty (bracketed-paste); always opt-in, gated by the paste-safety
confirm for large sets.

### Phase 36 — Session task templates / recipes — ✅ shipped

`Recipes.swift` — `~/.suit/recipes/*.md` (`<NAME>`/`<SELECTION>`/`<FILE>` placeholders, four seeded
built-ins) surfaced as "Recipe: <name>" palette entries that spin a worktree + `claude` + the filled
prompt in one keystroke. A manual launcher — no gating/auto-merge.

### Phase 37 — Edit files in Suit — ✅ shipped

The one thesis-sanctioned write slice: `FileEdit.swift` + `FileViewerPane+Editing.swift` make the
viewer editable with undo, debounced atomic autosave, ⌘S, a dirty dot, flush-on-close/quit, and
external-change reconciliation (ignore/reload/warn). Binary/too-large/unreadable stay read-only.

### Phase 38 — Fleet activity feed / daily digest — ✅ shipped

`Activity.swift` — an append-only `~/.suit/activity.jsonl` of notable transitions (session done/
needs-input, PR opened/merged, CI pass/fail, Autopilot merged/blocked); an "Activity" panel (newest
-first, repo/session/kind filters, row routing) and an optional once-daily digest notification.

### Phase 39 — GitHub PR review inbox — ✅ shipped

`PRReview.swift` / `GitView+PRInbox.swift` — a Git-tab inbox of PRs involving me (via gh); a row
opens the PR diff in the diff pane for Phase 16 line comments; "Submit as PR Review…" folds the draft
into a `gh pr review --approve|--request-changes|--comment` body.

### Phase 40 — File time-travel scrubber — ✅ shipped

`FileTimeTravel.swift` — a viewer "Time Travel" mode with a slider over the file's `git log --follow`
history; each position loads that revision via `git show <sha>:<path>` (highlighted, read-only) with
diff-to-neighbour marks; far right = working tree, never mutates the checkout.

### Phase 41 — Saved layouts / named workspaces — ✅ shipped

`Layouts.swift` — "Save Layout As…" snapshots a window's tab list + split tree (reusing
`StateRestoration` capture) into `~/.suit/layouts.json`; "Open Layout…" rebuilds it in a current/new
window (missing files collapse out); rename/delete/overwrite. Distinct from automatic quit-time
restoration.

### Phase 42 — Cost budget guardrails + auto-pause — ✅ shipped

Per-session and per-task spend caps in Settings (+ a fleet-row "Set Budget…"); crossing a cap notifies
(click → the pane) and, when auto-interrupt is on, sends Esc over the pty; every trip logs to the
activity feed. Complements Autopilot's start-gating budget modes as the per-run kill-switch.

### Phase 43 — Command history search (native ⌃R) — ✅ shipped

A native ⌃R fuzzy overlay (the ⌘P machinery) over shell history (`$HISTFILE` + per-pane scrollback,
source pane/cwd kept); picking a command types it into a chosen pane (⇧Enter edits-before-run;
destructive commands trip the paste-safety confirm).

## Cross-cutting principles ("works for the user")

- **Keyboard-complete**: every action has a binding and a palette entry; the mouse is optional.
- **Panes are cheap and disposable**: contents open as first-class tabs (files deduped by path);
  `⌘W` closes anything (tab first, then window).
- **State restoration** — ✅ shipped: reopen with the same layout, files, scroll positions, and
  worktree panes (terminals restart as fresh shells in their old cwd; see `StateRestoration.swift`).
- **No modes, no dialogs where a pane will do**; the app never steals focus — attention is *signaled*
  (badges, pulses), never *forced*.
- **Performance floor**: fuzzy-open < 50ms, search-first-result < 100ms, on the FSEvents file index.

## Risk notes

- **Tree-sitter grammars** are the one nontrivial vendoring job; shipped Phase 3 with a regex
  highlighter as the sanctioned fallback, swap later.
- **Session detection** depends on Claude Code hook/statusline stability, but both ends are controlled
  here and degrade gracefully (no file → the pane is just a terminal).
- **Scope creep toward "editor"**: hold the line — selection+copy and jump-to yes, typing into the
  buffer no, except the one autosave-guarded slice (Phase 37). Anything beyond it is Claude's job.
