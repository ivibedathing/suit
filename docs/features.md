# Features

The complete, detailed feature reference for [Suit](../README.md). The README keeps a
[Highlights](../README.md#highlights) summary; this document is the full description of what the
app does.

## Table of contents

- [Tabs & panes — tabs live on the pane](#tabs--panes--tabs-live-on-the-pane)
- [Files, search & navigation](#files-search--navigation)
  - [Files & sidebar](#files--sidebar) · [File viewer & navigation](#file-viewer--navigation) ·
    [Git review & inboxes](#git-review--inboxes)
- [Claude Code cockpit](#claude-code-cockpit)
  - [Sessions, attention & voice](#sessions-attention--voice) ·
    [Fleet control & spend](#fleet-control--spend) · [Talking to sessions](#talking-to-sessions) ·
    [Steering & review](#steering--review) · [Transcripts & history](#transcripts--history) ·
    [Tasks & recipes](#tasks--recipes)
- [Autopilot](#autopilot)
- [Appearance & settings](#appearance--settings)
- [Glassmorphism (transparency & blur)](#glassmorphism-transparency--blur)
- [Themes](#themes)
- [Safety](#safety)

## Tabs & panes — tabs live on the pane

- **Tabs on the pane** — every terminal, file, diff and transcript is a tab that belongs to a
  pane. When a pane holds more than one tab, an in-pane tab bar appears directly under its
  header to switch between them; a single-tab pane shows no bar. There is no window-level tab
  strip. ⌘T opens a fresh shell in the focused pane, ⌘W closes the active tab (a busy tab
  confirms first — the dialog's bold headline names the tab being closed), ⇧⌘T reopens,
  ⌘1–9 jump (⌘9 = last), ⌃Tab is a most-recently-used switcher (hold ⌃ to pick, quick tap to
  toggle the last two). Opening a file, diff, or transcript adds a tab to the focused pane's
  group.
- **Sessions sidebar** — the sidebar's Sessions tab (second in the activity bar, after Files) lists every
  open tab in the window, grouped by the pane (screen) that owns it — the cross-pane overview that
  replaces the old strip. Click a row to bring that tab forward in its pane; its close box
  shuts it. Session dots (busy / pulsing needs-input / done) and red failure dots show right
  in the list.
- **Panes are viewports** — split screen puts a tab in a new viewport beside the active one
  (⌘D takes the most recent background tab, or right-click a tab ▸ Split Screen, or drag a tab
  to a screen edge); the split-out tab becomes the new pane's own. Unsplit with ⌥⌘W (its tabs
  fold back into a neighbor), walk splits with ⌥⌘arrows. Closing the active tab falls back to
  another tab the same pane owns; background tabs keep their processes running.
- **Drag a tab into its own pane** — grab a chip from a pane's in-pane tab bar and drag it onto
  any viewport; it shows the same split-zone preview a pane drag does: drop on an outer half
  (left / right / top / bottom) to split it out into its own new pane on that edge, or drop on
  the center or the header to just show it in that pane (the displaced tab backgrounds, its
  process untouched). The tab previews as a pane header while you drag, so it's clear it can
  become a pane. Drag a chip clear of every window to tear it off into a new window of its own.
- **Exit status** — a clean shell exit closes its tab; a failure leaves it open with a red dot
  (hover for the signal/exit reason). Bells flash the pane and bounce the Dock icon while the
  app is inactive.
- **State restoration** — quitting snapshots every window's tab list, split tree, and viewer
  scroll positions; the next launch reopens it all, restarting terminals as fresh shells in
  their old working directories.
- **Saved layouts / named workspaces** — snapshot the current window's tab list + split tree
  under a name (**Save Layout As…**, in the Screen menu and the palette) and reopen it any time
  (**Open Layout…** — pick from a list; it rebuilds in a new window through the same replay path
  as quit-time restoration, so terminals restart as fresh shells in their old cwd and tabs whose
  file is gone collapse out). Rename, delete, and overwrite layouts from the palette; layouts are
  per-machine, shared across windows, and kept in `~/.suit/layouts.json`. Distinct from the
  automatic, unnamed quit-time restoration above.

## Files, search & navigation

### Files & sidebar

- **Activity bar** — a full-height icon strip pinned to the window's far-left edge, holding the
  sidebar's tabs: Files, Sessions, SSH Hosts, Notes and Bookmarks, top to bottom. It stays put
  when the sidebar is collapsed, so clicking any icon reopens the sidebar on that tab. Clicking
  the icon of the tab you're already on collapses the sidebar again (as ⌘B does).
- **Sidebar** (⌘B) — the panel beside the activity bar, showing the selected tab. The
  Files tab leads with a single project header — the folder name (a pin glyph when pinned) with
  search / choose-folder / unpin actions, and, inside a repo, a branch-switcher row with the
  repo's branch/worktree counts — and gives the rest of the tab to the tree. The tree is
  gitignore-consistent with the file index, shows sub-project badges (`go.mod`, `package.json`,
  …) and git status letters, and can be pinned to any folder.
- **Project search** (⇧⌘F, or the header's magnifier) — search isn't a permanent field: it
  drops a compact search bar over the tree only when you invoke it, and **Esc** (or the ✕)
  returns you to the file tree. Live ripgrep with regex/case toggles, a glob filter, and
  Project / Sub-project / Pane Directory scopes tucked behind the options button; results
  stream in grouped by file.
- **Open quickly** (⌘P) — fuzzy-find any file in the project index; ⌘K opens the command
  palette over every app command plus your prompt library.
- **Command history search** (⌃R) — the shell's reverse-i-search, made native and cross-pane. A
  fuzzy overlay (the same machinery as ⌘P) over your shell history (`$HISTFILE` / `~/.zsh_history`,
  deduped, most-recent-first) merged with the commands you've run in each pane this session (each
  row shows its source — `history` or the pane's folder). Type to filter, then **Enter** re-runs
  the picked command in the focused terminal pane, or **⇧Enter** types it in without submitting so
  you can edit it first. A destructive-looking command (curl/wget piped into a shell, `rm -rf`)
  trips the same confirm a risky paste does before it runs. With no history file, it falls back to
  the per-pane commands alone.
- **Notes** — a free-text scratch tab in the sidebar backed by `~/.suit/notes.txt`;
  right-click a terminal selection to append it as a note.

### File viewer & navigation

- **File viewer** — files open as tabs (deduped by path) with syntax highlighting, a
  minimap, line numbers, go-to-line (⌘L), and orange marks on lines changed since HEAD.
  Cmd-click a path in any terminal (with optional `:line`) to jump straight to it. Files are
  first-class tabs: every open (sidebar click, ⌘P, search hit, Cmd-click link) opens the
  file's own tab or re-activates it if the path is already open — files never load one on top
  of another, so opening three files leaves three tabs.
- **Edit files** — the viewer is editable: type into the buffer (undo with ⌘Z) and it
  **autosaves** to disk on a short debounce, or save now with **⌘S** (File ▸ Save / palette
  "Save File"). An accent dot on the tab (in place of its close ✕ until you hover) and in the
  pane header marks unsaved edits; pending edits also flush when you close the tab or quit.
  Binary, over-8 MB, and unreadable files stay read-only. Editing stays a deliberate, bounded
  slice — Suit is still viewer-first, with Claude doing the heavy code-writing.
- **Live reload on outside changes** — open tabs track their file on disk. When something else
  rewrites it — Claude editing the file you're reading, `$EDITOR`, a branch switch, a build
  regenerating an asset — the tab updates within a fraction of a second, no click or refocus
  needed. In the viewer a **clean buffer silently reloads**, keeping your scroll position, and
  one with **unsaved edits asks** whether to keep your edits (your next save wins) or reload
  from disk; only one such prompt is ever up at a time, however many writes land while you
  decide. Markdown, image and PDF tabs re-render in place, holding your scroll position, your
  `<details>` toggles, and your PDF page. A time-travel scrubber is never reloaded over.
  Deleted files keep showing their last content and pick the change back up if the file
  returns — a `git checkout` that removes and rewrites a file lands correctly. Bursts of writes
  coalesce into one reload, so a generator writing in chunks costs one re-render, not one per
  chunk.
- **Blame gutter** — Toggle Blame (⌃⌘B) shows a per-line column of the last-touching commit
  (short sha + author, tinted by age) beside the line numbers; the full commit subject is on
  hover, and clicking a line's sha opens that commit's diff.
- **File history** — Show File History opens the Git tab's list of commits touching the open
  file (`git log --follow`) — sha, subject, author, age; click a commit to open its per-file
  diff.
- **Time travel** — **Time Travel** (⌃⌘H, the palette, or the viewer's right-click menu) turns
  that history into a scrubber: a bar across the top of the viewer with a slider over every
  revision (oldest on the left, the working tree pinned at the far right, HEAD one step in).
  Drag it and the read-only viewer loads each revision's content (`git show <sha>:<path>`,
  syntax-highlighted as usual), the header showing sha · subject · age. Each position marks its
  change versus the adjacent older revision as orange gutter bars, and **Diff** flips that
  commit's per-file change into the diff tab. It's read-only and non-destructive — nothing is
  ever checked out — untracked files say "no history", and **Exit** (or toggling the command
  off) restores the working-tree view.
- **Commit graph** — **Show Commit Graph** (the Git tab's graph button, or the command palette)
  opens a read-only, clickable rendering of the whole commit DAG (`git log --all --date-order`):
  nodes laid out in lanes with edges for merges and forks, short sha · subject · author · age
  (tinted by age like the blame gutter), and branch / tag / HEAD badges on their tips (the current
  branch in accent). Click a node to open that commit's diff. It refreshes on commit / branch /
  worktree operations, and large histories cap with a **Load more** button. One graph tab per
  window, reused like the diff and transcript tabs.
- **Find & replace in the file viewer** (⌘F, ⌥⌘F for the replace row) — a VS Code-shaped bar that
  floats over the top-right of the text rather than pushing it down. Matching is incremental: every
  hit is washed in accent as you type, the current one more strongly, with a `3 of 17` counter.
  ⌘G / ⇧⌘G (or the ‹ › buttons, or Return / ⇧Return in the find field) step through matches and
  wrap at both ends; ⌘F from mid-file selects the match *below* the caret rather than jumping back
  to the top. Three toggles mirror VS Code's: **Aa** match case, **ab** whole word, **.\*** regular
  expression — a bad pattern reads "Bad pattern" instead of matching nothing silently. Whole-word
  works for queries ending in symbols (`foo(` matches), which a `\b`-wrapped pattern can't do.
  Replace does the current match (Return in the replace field) or all of them at once; in regex
  mode `$1` interpolates capture groups, while in plain mode it stays the literal characters `$1`.
  A Replace All is a **single undo step**, not one per match. ⌘E puts the selection on the system
  find pasteboard, so a query carries between panes and from other apps. Esc closes and hands focus
  back to the text. Find works everywhere — including read-only buffers like a time-travel revision
  or a binary placeholder — but replace disables itself wherever the buffer can't be written, so it
  can never fail at save time instead of up front. Terminals keep SwiftTerm's own find bar on the
  same ⌘F.
- **Go to definition & find references** — Cmd-click an identifier in the viewer (or Go to
  Definition, ⌃⌘J) to jump to where it's defined; several definitions open a palette picker,
  each `file:line` with its kind. Find References (⌃⌘R) opens a references pane listing every
  use of the symbol, grouped by file, each row a click into the viewer at that line. Both are on
  the viewer's right-click menu too. A bundled `universal-ctags` builds the symbol index per git
  root (refreshed as files change); when it isn't installed, navigation degrades to a
  whole-word ripgrep search with a note in the header — set `SUIT_CTAGS_PATH` or rebuild with
  universal-ctags on PATH to enable the index.
- **Preview tabs** — the viewer routes by extension, so previewing a README or a design asset
  never means a trip to Finder. Markdown (`.md`/`.markdown`) renders as a proper document in a
  centered reading column (capped at ~720pt, margins grow with the pane, like GitHub/Typora),
  set in proportional reading type — at least 16pt with roomy line spacing, scaling up with the
  pane font (⌘= / ⌘-):
  ATX and setext headings on a GitHub-style scale with hairline rules under H1/H2, hard-wrapped
  source lines joined into flowing paragraphs, nested bullet/ordered lists with hanging indents,
  task-list checkboxes (`- [ ]` / `- [x]`), fenced code as full-width padded cards
  (syntax-colored), blockquotes with a left bar, pipe tables as real grids (header row shaded,
  `:---:` alignments honored), full-width horizontal rules, images (scaled to the column), and
  inline bold/italic/strikethrough/code plus clickable links — with a Rendered ↔ Raw toggle.
  Images render wherever READMEs put them: local paths and remote `http(s)` sources, block
  `![alt](src)` lines, inline images and `[![badge](src)](href)` linked badges in prose, and
  animated GIFs (which play, rather than freezing on the first frame). Remote images fetch
  asynchronously into a shared per-run cache — the alt text shows as a dim placeholder until
  the bitmap lands, and stays if the fetch fails.

  The raw-HTML subset READMEs lean on renders too, rather than showing as literal tags: the
  `<p align="center">` / `<div align="center">` idiom, `<h1 align="center">` headings,
  `<a href><img></a>` badge rows, inline `<strong>`/`<em>`/`<code>`/`<br>`, and `<img>` with
  its `width`. `<details>`/`<summary>` renders as a real disclosure — click the summary to
  expand or collapse it, and `open` starts it expanded. Anything outside that whitelist falls
  back to showing the source verbatim, whole: the parser fails closed on purpose, so an
  unrecognized tag degrades to the old behavior instead of rendering half-understood markup.
  Images (PNG/JPG/GIF/SVG/…) open over a checkerboard backing with a zoom-to-fit /
  actual-size toggle and the pixel dimensions in the header. PDFs open in a PDFKit view with a
  page-thumbnail rail. All three are ordinary tabs, so split, drag, path-dedupe, and state
  restoration (scroll / zoom / page) work unchanged.
- **Bookmarks** — pin a specific `file:line` with ⇧⌘L (or click the gutter) — an amber tick
  shows in the viewer gutter and minimap. The Bookmarks sidebar tab lists them; Enter or
  double-click reopens the file at that line, right-click renames or removes. Saved in
  `~/.suit/bookmarks.json`, shared across windows, dead paths pruned automatically.

### Git review & inboxes

- **Diff view** — `git diff HEAD` as a tab (⌃⌘D), unified or side-by-side with scroll-locked
  halves; review mode walks changed files with n/p and opens the file under review with o.
  A commit ref (from a blame sha or a File History row) opens that commit's per-file diff.
- **Review comments → Claude** — in a diff, press `c` on a line to attach a review comment
  (GitHub-PR style); comments render inline in amber and collect into the pane's review draft.
  The header's **Review (N)** button lists them (edit / delete / open file), and **Send Review
  to Session…** (also in the palette) pipes the whole batch into a chosen Claude session as one
  structured prompt, then clears the draft. Comments persist across restarts with the diff tab.
- **Branch / worktree switcher** — the Files tab header's branch row shows the checked-out branch
  with a branch/worktree count; click the branch name to drop a switcher menu of the repo's
  **worktrees** (pick one to repoint the whole sidebar there) and **local branches** (pick one to
  check it out). Picking a worktree also **walks the open terminals over** to it: every visible
  shell sitting idle at a prompt inside the repo's worktree tree gets `cd`'d to the matching spot
  under the new worktree (same relative subpath when it exists there, otherwise the worktree root),
  so the terminal you're looking at actually lands on the new branch. Terminals mid-job (running
  `claude`, a build, `vim`) are left alone.
- **Git surface** — the git review surface has no activity-bar icon; reach it with
  **Show Git** in the command palette. It shows staged / changed files (click to open the scoped
  diff) and, below them, a **Branches** list: every local branch with its ahead/behind vs
  upstream (green ↑ / amber ↓), a worktree glyph, and a dirty dot; the current branch is
  highlighted. Click a branch to check it out (or switch the sidebar to its worktree).
- **Branch → PR** — right-click a branch for gh actions: **Create PR…** (title prefilled from
  the branch, body from its commits), **Open on GitHub**, and **Checkout**. When a PR exists it
  shows a `#N` badge with a ✓/✕/• checks glyph. Everything degrades gracefully without the `gh`
  CLI — the menu still checks out, and shows a hint to install gh.
- **"What changed while I was away"** — start Claude sessions across a repo's worktrees, step
  away, and come back to *one* diff of everything that moved. The Git tab's ⚑ button (or the
  palette's **Mark Now**) records a per-repo checkpoint — every worktree's HEAD plus a timestamp,
  in `~/.suit/markers.json`; the flag fills once a mark is set. **What Changed Since Mark**
  (⚑ menu or palette) then composes an aggregate diff across *all* the repo's worktrees — each
  worktree's commits, staged, unstaged, and newly-created files since the mark — into one review
  set in the diff tab, walkable with the usual `n`/`p`/`o`/`c`. A summary header leads it:
  files-touched and `+ins −del` per worktree, and which Claude session (matched by cwd) is
  working there, so the catch-up reads as "session X changed these 6 files". Worktrees created
  after the mark diff from their merge-base, so only their new work shows.
- **Feedback inbox** — a **Feedback** section at the top of the Git tab surfaces machine feedback
  across the repo's worktrees: **CI failures** (failing checks + a tail of the failed run's log,
  via `gh`), **PR review comments** (reviews + conversation comments, via `gh`), and **merge
  conflicts** (unmerged files, pure git — shown even when GitHub is unreachable). Each row is
  attributed to the **originating Claude session** (resolved by the same worktree/cwd session
  map) and shows `→ <session>`, or `route to a session…` when attribution is ambiguous. Click a
  row (or right-click ▸ **Route to Session…**) to compose the failure log / comments / conflict
  list into one structured prompt and inject it into that session's pty — with a session picker
  when the match is ambiguous, never a guess. Right-click ▸ **Start Review Pass in Worktree**
  kicks a fresh `claude` in the worktree primed to review the branch. Palette: **Show Feedback
  Inbox**, **Route Feedback to Session…**.
- **PR review inbox** — a **PR Review Inbox** section in the Git tab lists open PRs that involve
  you — authored, assigned, or review-requested (via `gh`, loaded off the main thread; hidden
  without `gh`). Each row shows the PR title, `#N` with a check-rollup glyph (✓/✕/•), author, and
  branch. Click a row (or right-click ▸ **Review Changes**) to fetch the PR's diff (`gh pr diff`)
  into the diff pane and review it with the same line comments as a local diff — press `c` on a
  line, walk files with `n`/`p`. Then the Review menu's **Submit as PR Review…** (or palette
  **Submit PR Review…**) pops one dialog to pick a verdict — **Approve** / **Request Changes** /
  **Comment** — plus an optional overall note; your line comments fold into the review body and it
  posts via `gh pr review`. Right-click ▸ **Open on GitHub** opens the PR page. Palette: **Show PR
  Review Inbox**, **Submit PR Review…**.
## Claude Code cockpit

### Sessions, attention & voice

- **Session awareness** — an installer (app menu ▸ "Install Claude Code Integration…") wires
  Claude Code's statusline and hooks to `~/.suit`. Panes running Claude sessions show a state
  dot (busy / pulsing needs-input / done) and a context-fill %, the sidebar footer shows global
  5h/7d usage, and the Sessions sidebar tab lists every open tab with its live session dot.
- **Attention** — a session that needs input while Suit is inactive posts a notification
  (click to jump to its pane) and badges the Dock with the needs-input count. Additionally,
  Suit plays a macOS system sound when a Claude session finishes a task and a different one
  when it needs input / asks a question; sounds play only while Suit is in the background
  (no sound when it's the active app). Each event has its own on/off toggle and its own
  sound picker in Settings ▸ Claude; defaults are Glass (finished) and Ping (question), both on,
  and picking a sound previews it.
- **Dictation (speech to text)** — hold the **🌐 (Globe / Fn)** key to talk; release and the
  transcribed text drops into the focused pane's prompt (it is *not* auto-submitted, so you can
  review and edit before Enter). A small "Listening…" HUD shows the live transcription. Recognition
  is **on-device** (Apple's Speech framework) — no network, no API key, works offline. First use
  prompts for microphone and speech-recognition access. **Dictate…** in the command palette (and
  View menu) primes that permission and reminds you of the gesture. If holding 🌐 pops the emoji
  picker instead, set *System Settings ▸ Keyboard ▸ Press 🌐 key to* → **Do Nothing**.

### Fleet control & spend

- **Fleet dashboard** — "Show Fleet" (⇧⌘O, or the command palette) opens a floating,
  cross-window panel listing every live Claude session as a row — status dot, current task,
  project · worktree · branch, context %, and cost — sorted needs-you-first, so one glance
  answers "who needs me right now" without hunting through tabs. Each row steers the session
  in place: **Focus** (bring its window + pane forward), **Esc** (interrupt), **Continue**, and
  **Stop** (close the session's tab); double-clicking a row focuses it. A **Board** toggle lays
  the same sessions out Kanban-style (Running / Needs you / Done), one card per worktree —
  click a card to jump to it. Actions are only enabled for sessions a pane still hosts.
  A session that fans out into `isolation: worktree` **subagents** shows them nested (indented)
  underneath it — one row per subagent worktree (name + branch), muted when it has no live
  session of its own — discovered from the repo's worktree list and pruned automatically as
  Claude Code removes each finished subagent's checkout.
- **Broadcast** — fan one instruction across many sessions at once (iTerm's "send to all
  sessions"). Check rows in the fleet dashboard and hit **Broadcast Selected (N)**, or
  **Broadcast All** for every live session — either opens the composer aimed at that set; type
  once and Enter sends it into every target's pty as one bracketed-paste unit. "Broadcast to
  All Sessions…" (command palette / View menu) is the keyboard path. A fan-out confirm gates
  before it lands in two or more panes; only sessions a pane still hosts are reached.
- **Activity feed / daily digest** — where the fleet dashboard is a live snapshot of *who's
  busy*, "Show Activity Feed" (command palette / View menu) opens a floating panel with the
  chronological record of what *moved* across the fleet: sessions finishing or stalling on
  input, CI failing, and Autopilot runs merging or blocking — newest-first, each row a
  tone-colored glyph + title + repo · worktree/PR + relative age. Filter by repo or kind, and
  click a row to jump to the thing it names (the session's pane, the PR on GitHub, or the
  Autopilot log). The events persist to `~/.suit/activity.jsonl` (append-only, so history
  outlives session-file pruning). A header shows a **"what happened today"** recap — sessions
  finished · PRs merged · autopilot merges · CI failures — and once per day Suit delivers the
  previous day's digest as a notification (click it to open the feed).
- **Cost budget guardrails** — per-session and per-task (worktree) spend ceilings that watch each
  run's `cost_usd`. Set the defaults in Settings (⌘, ▸ Budget) as dollar caps (blank = off), or
  give one session its own ceiling with **Set Budget…** (right-click a fleet-dashboard row, or the
  "Set Session Budget…" palette command). When a session — or the summed spend of all sessions in
  a worktree — crosses its cap, Suit posts a notification (click it to focus the pane) and logs the
  trip to the activity feed; it never fires more than once per crossing. Tick **"Interrupt the run
  (Esc) when a cap is crossed"** to also send Esc into the offending pty and halt it — never
  silently. This is the per-run kill-switch that complements Autopilot's global 5h/weekly start
  gates: an in-flight run that blows a task cap trips here.

### Talking to sessions

- **Talk-back** — send prompts into any session's pty: quick actions (Prompt… / Continue /
  /compact / Interrupt), a floating composer with `@`-completion over repo files, a prompt
  library (`~/.suit/prompts/*.md`), or right-click ▸ "Send Selection to Claude Session" to pipe
  an error/diff/log line over with context.
- **Slash-command menu** — "Slash Command Menu…" (⌃⌘/, or the command palette) lists a chosen
  session's available commands — Claude's built-ins (`/context`, `/compact`, `/clear`, `/usage`,
  …), your custom `~/.claude/commands/*.md`, and skills (each project's own `.claude/` is scanned
  too) — and dispatches the one you pick straight into that session's pty. A session picker appears
  first when several are live.
- **One-tap /compact** — the pane title bar's context-% meter is a button: click it (or press
  ⌃⌘K, "Compact Focused Session") to send `/compact` into the focused session, so acting on a
  full context window is one tap instead of a typed command.

### Steering & review

- **Set as Goal** — select code or prose in a file viewer, transcript, or terminal, then
  right-click ▸ "Set as Goal" (or the palette's "Set Selection as Claude Goal") to send
  `/goal <selection>` into a chosen session — turning "this is what I want done" into a
  two-click gesture. Sent as one bracketed-paste unit (multi-line selections stay intact) and
  submitted; a session picker appears when several are live, defaulting to the last one you
  targeted. An optional setting prepends the source location (`From <file>:<lines>:`).
- **Mode control** — switch a Claude session's permission mode from the palette
  (`Claude: Ask/Plan/Agent Mode`), which writes the right number of Shift+Tab presses into the
  session's pty (so you never have to guess which invisible mode a pane is in). The switch tracks
  the session's `permission_mode` when the hooks report it, else the last mode Suit sent.
- **Plan review** — when a session in Plan mode proposes a plan (Claude's `ExitPlanMode`), open it
  with `Claude: Review Plan…`: the plan renders read-only as numbered steps with **Approve & Run**
  / **Edit** / **Discard** buttons that inject the matching choice into the session. A *Refresh*
  re-parses the latest plan from the transcript.

### Transcripts & history

- **Transcripts** — open a live-tailing, read-only render of any session's transcript; file
  paths in it are clickable like terminal links.
- **Checkpoint timeline** — "Open Checkpoint Timeline…" shows a session's automatic pre-change
  checkpoints (the ones `/rewind` restores) as a read-only, live-tailing timeline, newest first:
  each node carries its timestamp, the prompt that triggered it, and the files it backed up.
  Click a file to open it *as it was* at that checkpoint in a viewer tab; the header's "Rewind in
  session…" opens Claude's native `/rewind` picker right in the pane.
- **Cross-transcript search** — "Search Transcripts…" (⌃⌘F, or the command palette) opens a
  floating query field over every Claude session's history (`~/.claude/projects/**/*.jsonl`),
  searched with ripgrep. Results are readable snippets — prompts, replies, tool calls — grouped
  by session (name · project · date), and clicking one opens that session's transcript anchored
  to the matching line.

### Tasks & recipes

- **Worktree tasks** — "New Claude Task…" (⌃⌘T) opens a pane running `claude` for a named task;
  finishing the task merges or discards its worktree. The prompt carries an **Isolate in
  worktree** switch — on (the default) spins a dedicated git worktree on a `task/…` branch, off
  runs `claude` straight in the current checkout for cheap tasks that don't want the worktree
  churn. The switch's default is a setting (Settings ▸ Claude ▸ "Isolate new tasks in a worktree
  by default").
- **Session recipes** — parameterized task templates. Drop a `~/.suit/recipes/*.md` file (an
  optional `---`-fenced `name:` front matter plus a body prompt with `<NAME>` / `<SELECTION>` /
  `<FILE>` placeholders) and it surfaces as a **Recipe: <name>** palette entry; four built-ins
  (bug fix, feature, refactor, review) are seeded on first run. Picking one prompts for a task
  name (with the same **Isolate in worktree** toggle), fills `<NAME>` from your input and
  `<SELECTION>`/`<FILE>` from the focused viewer/terminal, spins the worktree + `claude`, and
  sends the substituted prompt in — a bugfix / feature / refactor / review each launching in one
  keystroke instead of a manual setup ritual. Manual and interactive (no gating or auto-merge,
  unlike Autopilot).
- **Background-task monitor** — long-running jobs Claude Code (or you) background — dev servers,
  test watchers, builds — are invisible from Suit's side until you scroll the shell. Launch one
  through the bundled `suit-bg` wrapper (`suit-bg npm run dev`) and it runs detached with its
  output captured to a log, tracked by the monitor pane: a terminal's right-click ▸ **Show
  Background Tasks** (or the palette's **Show Background Tasks**) opens a live list of that shell's
  background jobs — **command**, a status dot (**running** / **done** / **failed**), the
  **listening port** when detectable — over a live tail of the selected task's captured output.
  A job that **fails** (or crashes) rings the monitor tab like a bell and folds a
  "N failed" suffix into its header, so a dev server that fell over is noticed without spelunking
  scrollback. Records live in `~/.suit/tasks/` (written by `suit-bg`, atomic, no dependencies) and
  are pruned a day after their process ends. The wrapper ships in the app bundle
  (`Suit.app/Contents/Resources/suit-bg.sh`) — symlink it onto your `PATH` to use it as `suit-bg`.

## Autopilot

- **Autonomous roadmap execution** — Autopilot works through a project's `ROADMAP.md` on its
  own: whenever the token budget allows, it creates a git worktree for the next unshipped
  phase and opens a visible tab running `claude` in it; the worker implements the phase,
  builds, updates the docs, pushes, and opens a PR. Suit then gates the PR — `./build.sh` must
  exit 0 and a headless Claude review must approve — auto-merges it, cleans up the worktree,
  and loops to the next phase. Gate failures feed the build-log tail or review findings back
  into the live session for another attempt (capped by the Attempts setting); anything
  unrecoverable blocks Autopilot with a notification, keeping the worktree, branch, PR and
  logs for inspection (the palette's Retry resumes). Merged phases post a notification too.
  Needs the `gh` CLI (installed and authenticated) and the Claude Code integration.
- **Multiple autopilots at once** — Autopilot is per-repo, and several run concurrently, one
  per git repository. **`Autopilot: Start Here`** (palette) resolves the active tab's working
  directory up to its git root, requires a `ROADMAP.md` there, and stands up an autopilot for
  that repo — so you launch a run from wherever you're looking, no Settings trip needed. The
  configured project (Settings ▸ Autopilot) still auto-runs on launch as the "primary". Because
  every worker draws on the *same* Claude budget, only **one instance holds a live run at a
  time**: the others sit **queued** and take the slot the moment it frees (the budget modes
  below still decide when the active slot may start a new phase). Each instance keeps its own
  state, history, and logs, and a running autopilot is re-adopted on the next launch.
- **Start/stop from the terminal** — a terminal pane's right-click menu carries one Autopilot
  item that flips with the state of the repo that pane's shell is sitting in: **Start Autopilot
  Here** when nothing is running on it, **Stop Autopilot (<repo>)** when something is. Start is
  the palette's `Autopilot: Start Here` aimed at *that pane's* working directory rather than the
  focused tab's, so it runs the same enable-time checks and reports the same problems (not a git
  repo, no `ROADMAP.md`); Stop matches the dashboard's — the instance goes away, its worktree and
  branch stay put. A pane inside a worker's own worktree (`.claude/worktrees/…`) counts as inside
  the project driving it, so you can stop a run from the shell you're watching it in. The menu
  answers from paths alone and never shells out to `git`, so right-click stays instant.
- **Autopilot dashboard** (`Autopilot: Dashboard`, or click the footer row when more than one
  is active) — a floating panel with one row per running autopilot: the repo, its live status,
  and per-repo controls — Focus run tab, Pause/Resume, Skip Current Phase, Retry (while
  blocked), Show Log, and **Stop** (drop that instance without touching its worktree). A
  **Start Here** button launches a new one on the active tab's repo.
- **Per-phase model & effort routing** — a phase's `ROADMAP.md` body can carry `model:` and/or
  `effort:` annotation lines (bare or `- `-led, case-insensitive key, value verbatim — e.g.
  `model: haiku`, `effort: low`), and Autopilot launches that phase's worker with
  `ANTHROPIC_MODEL` / `CLAUDE_CODE_EFFORT_LEVEL` set accordingly, so mechanical phases (doc
  sweeps, renames, migrations) run on a cheaper tier while design-heavy phases keep the session
  default. The annotations are snapshotted onto the run at spawn (like the spec) and survive
  `--continue` respawns; the first occurrence per phase wins, and prose mentioning "the model:"
  mid-sentence never triggers. The in-repo annotation is the explicit, versioned opt-in. A phase
  with no annotation is routed automatically — see below.
- **Automatic model routing** — a phase with no `model:` annotation is routed by asking **haiku**
  which tier the work deserves: it reads the phase's spec text and answers `HAIKU` (mechanical and
  local — a typo, a rename, a version bump), `SONNET` (ordinary feature work following patterns the
  codebase already has), or `OPUS` (design decisions, concurrency, migrations, cross-cutting
  refactors, or a goal stated without a method). The classifier costs a fraction of a cent and runs
  during the worktree checkout the spawn was already waiting on, so it adds no perceptible delay.
  Ties break upward on purpose: a rejected review gate costs more than the model ever saved. The
  decision and its source land in the Autopilot log (`model routing: opus (haiku classifier)`).
  Precedence is **roadmap `model:` annotation → classifier → heuristic**: an annotation is never
  overridden or second-guessed (and never pays for a classifier), and if the classifier can't
  answer — no `claude` binary, a timeout, unparseable output — a local keyword/breadth heuristic
  picks instead, biased upward and never below `sonnet` unless the request is unmistakably
  mechanical. Routing is advisory: every failure path lands on a tier, none can block a run.
  Toggle it with **Settings ▸ Autopilot ▸ "Route each phase to a model tier"** (on by default);
  off restores the previous behaviour of letting claude pick.
- **Routed review gate** — the review gate follows the tier the phase's work was routed to, so a
  haiku-routed typo isn't reviewed by opus, without spending a second classifier call. It never
  drops below **sonnet**, however cheap the phase was: the review gate is a correctness gate, and a
  reviewer that rubber-stamps is worse than no gate because it launders a bad change into a merge.
  An explicit **Reviewer** value in Settings ▸ Autopilot is a standing decision and outranks
  routing entirely (empty = routed, or claude's default when routing is off).
- **Unchanged-diff review skip** — every review verdict records a fingerprint of the exact PR
  diff it judged; if the next review attempt sees a byte-identical diff (the worker pushed
  nothing real since the rejection), the headless review is skipped — no API spend — and the
  worker instead gets told plainly that nothing changed and to address the previous findings.
  The skip still consumes a review attempt, so a worker that never changes anything runs into
  the attempts cap rather than looping forever.
- **Budget modes** — three switchable modes decide when a run may *start* (a run in flight
  always finishes): **Pace to reset** spreads the weekly budget evenly across the rate-limit
  window, **Max out** runs whenever usage is under the ceilings, **Night shift** is max-out
  restricted to the configured night hours (default 22–7, wrapping midnight). All modes
  respect the 5h cap and the weekly hard stop; the weekly cap additionally bounds Max out
  and Night shift (Pace to reset follows its own pace line instead).
- **Settings** (⌘, ▸ Autopilot) — the enable checkbox ("Work through ROADMAP.md
  autonomously"), the project (a git repo containing ROADMAP.md, with a Choose… picker), the
  mode and night hours, the 5h / Weekly / Hard Stop / Pace To percentages, max gate attempts
  per phase, the needs-input stall minutes, extra `claude` arguments for worker runs
  (`--dangerously-skip-permissions` is always set), the review-gate model (empty = default),
  and "Keep the Mac awake during runs".
- **Status row** — a one-line status in the sidebar footer, above the usage rows: `Autopilot ·
  next run ~03:40`, `⚙ Phase 23 · running 41m`, `⚙ Phase 23 · gate: build`, `⚙ Phase 23 ·
  merging PR #142`, `⚠ Phase 23 blocked — …`, `Autopilot · queued` (waiting behind the active
  instance). With several autopilots active the row shows the running (or primary) one prefixed
  with its repo and a `· N autopilots` count. Clicking it opens the dashboard when more than one
  is active, else focuses the run tab (while running) or the log; the tooltip carries the full
  reason.
- **Palette commands** — `Autopilot: Enable`/`Disable` (the title flips) and `Autopilot: Show
  Log` are always there; while enabled, also `Start Here (active tab's repo)`, `Dashboard`,
  `Run Next Phase Now` (bypasses the budget gate once), `Pause After Current Run`/`Resume`,
  `Skip Current Phase`, and `Open Run Tab`, plus `Retry` while blocked. The run-control verbs
  act on the current instance (running / primary / first active). No new keyboard bindings —
  palette-reachable is keyboard-complete.
- **The run tab** — the worker is an ordinary terminal tab titled `⚙ Phase N — <Title>`,
  opened without stealing focus; watch it, split it, or type into it (the session dot pulses
  on needs-input as usual). A worker exit never auto-closes the tab, so the scrollback
  survives for debugging.
- **Steering = editing ROADMAP.md** — phase priority is document order; `✅` anywhere in a
  phase heading means shipped, `⏸` means skipped ("Skip Current Phase" appends it — the
  engine's one write to the file). When every phase is shipped or skipped, Autopilot idles
  until the roadmap changes again.
- **On disk** — each autopilot owns a per-repo slot under `~/.suit/autopilot/repos/<slug>/`
  holding `state.json` (its current run — it survives a relaunch, and Autopilot resumes it at
  the right stage), `history.jsonl` (one row per finished run: outcome, PR URL, attempts,
  cost), `autopilot.log` (the human-readable event log Show Log opens as a viewer tab), and
  `logs/<phase-slug>/build-N.log` / `review-N.log` (gate output). Cross-instance events
  (enable/disable, Start Here, Stop) go to the top-level `~/.suit/autopilot/autopilot.log`. The
  old single-autopilot layout (files directly under `~/.suit/autopilot/`) is migrated into the
  primary repo's slot automatically on first launch. A `~/.suit/autopilot-prompt.md`, when
  present, overrides the worker prompt template.
- **What the worker and the review gate are told** — the worker prompt points at `AGENTS.md`
  for the repo's conventions and asks for the shipped behavior to be documented in
  `docs/features.md`, touching `README.md` only when the change belongs in its Highlights
  summary or shortcuts table. The review gate judges against the same targets, and the repo
  rules it reads are `AGENTS.md` from the *main* checkout (never the worker's edit of them),
  capped at 40 KB with a truncation marker so the gate knows when it judged a prefix.

## Appearance & settings

- **Settings** (⌘,) — a category sidebar (macOS System-Settings style) with one pane per topic,
  so only the settings you're changing are on screen: **Appearance** (font and default size,
  text color, default pane background, opacity (⌘] / ⌘[), blur (⇧⌘B)), **Terminal** (the shell
  new tabs run, cursor shape and blinking, bell responses — pane flash, Dock bounce),
  **File Viewer** (word wrap), **Claude** (session arguments, "Set as Goal" provenance, and
  notification sounds), **Themes** (swap the whole color palette — see below),
  **Autopilot**, **Budget**, and a read-only
  **Shortcuts** reference. Everything persists across launches.
- **Update check** — Suit polls the GitHub releases of its own repo (at most one API hit per day,
  re-evaluated shortly after launch and every 6 h for long uptimes) and, when a release tag newer
  than the running version ships, posts a notification; clicking it opens the offer dialog with
  the release notes and **Download** / **Remind Me Later** / **Skip This Version**. Download opens
  the release's `.dmg` (or the release page when there's no `.dmg` asset) in the browser — you
  install it yourself by dragging the new app into Applications; Suit never replaces itself.
  Skipping silences that tag until a newer one appears. **Suit ▸ Check for Updates…** (also in the
  ⌘K palette) checks immediately, ignoring the throttle and any skipped version, and always
  answers — offer, "You're up to date", or the error. State (last check, skipped tag) lives in
  `~/.suit/update-check.json`.
- **Per-pane looks** — right-click a pane for background presets or a custom color, per-pane
  font size (⌘= / ⌘-), and a decorative ASCII screensaver overlay (waves/stars) with its own
  colors and speed. Terminals ground a step darker than the chrome: "Midnight" (#0E1013) is the
  default terminal background, giving shell output its own deeper layer, while "Slate" keeps the
  one-surface chrome ground (#17191D) available per pane. Dracula, Nord, Solarized Dark and more
  round out the presets.

## Glassmorphism (transparency & blur)

Like the native macOS Terminal, only the **terminal panes** go translucent — the window's title
bar stays solid, and file/diff/markdown viewers stay opaque for legibility.

- **Real transparency** — the **Opacity** slider in **Settings ▸ Appearance** (or ⌘] / ⌘[)
  lowers each terminal's background alpha so the desktop shows *through* the terminal, while the text
  itself stays fully opaque and crisp. The slider reaches down to 5% opacity, so the glass can go
  almost fully clear.
- **Background blur** — the **Background Blur** checkbox (⇧⌘B) puts a behind-window frost directly
  behind each translucent terminal, so it reads as a pane of frosted glass rather than a plain
  see-through hole. The frost sits *under* the terminal only, so the title bar and chrome keep their
  solid backing. Blur only becomes visible once transparency is below 100% — there's nothing to see
  through an opaque pane.
- **Blur amount** — the **Blur** slider (below Opacity in **Settings ▸ Appearance**) tunes how soft
  the frost is, from 0 (tinted but sharp glass — the desktop stays readable through the terminal) up
  to roughly twice the stock system blur. The default (30) matches the system frost exactly. The
  slider takes effect while the Background Blur checkbox is on and the terminal is translucent, and
  it applies live to every open terminal pane.

## Themes

- **What a theme is** — a full set of Suit's color tokens: chrome, text, accent, and the
  session/semantic status colors. Metrics (padding, sizes, corner radii) and fonts stay fixed, so a
  shared theme can recolor the app but never break its layout. A theme can be dark, light, or
  high-contrast — the window chrome is drawn from whichever palette is active.
- **Switching** — pick a theme from **Settings (⌘,) ▸ Themes**; clicking one applies it live and
  instantly, no relaunch. For quick cycling without opening Settings, run **Switch Theme…** from the
  command palette (⌘K). Three themes ship built in: **Suit Dark** (the default — the exact look
  you've always had), **Midnight**, and **Suit Light**. The selection persists across launches, so
  the app opens already themed.
- **Creating & editing** — built-in themes are read-only. **Duplicate** turns one into an editable
  user theme, then **Edit** exposes a color well for each of the ~15 tokens with a live preview
  strip; changes apply as you pick. `focusBorder` and `selection` aren't editable — they derive from
  the accent color automatically.
- **Import / export** — **Import** takes a `.suittheme` file (via the file picker or by dropping it
  onto the Themes list), copying it in as a new user theme. **Export** writes the selected theme's
  `.suittheme` file to a location you choose. **Delete** removes a user theme (built-ins can't be
  deleted).
- **Sharing** — user themes live one file per theme under `~/.suit/themes/`, so sharing a theme is
  literally copying its `.suittheme` file — paste it into chat or a gist and the other person
  imports it. The format is plain JSON:

  ```jsonc
  {
    "name": "Nord",
    "author": "someone",
    "schema": 1,
    "colors": { "bg": "#2E3440", "accent": "#88C0D0", "textPrimary": "#ECEFF4" }
  }
  ```

  Colors are `"#RRGGBB"` hex strings (a leading `#` is optional and case doesn't matter). Every
  color is optional: any token a file omits — or spells wrong — falls back to the built-in default,
  and unknown keys are ignored, so partial themes and themes authored against an older or newer Suit
  still load cleanly.

## Safety

- **Paste safety** — pasting multi-line text or `curl`/`wget`-into-a-shell one-liners prompts
  with a preview of exactly what's about to be sent.
- **Clipboard hygiene** — OSC 52 "copy to clipboard" from remote/tmux sessions works, but
  OSC 52 *read* queries are denied outright, so nothing in a pane can silently read your
  clipboard.
- **Login shells** — shells start login+interactive (`-l -i`), so `~/.zprofile` PATH setup
  (Homebrew) and `~/.zshrc` (Powerlevel10k, oh-my-zsh) load the same as in Terminal.app.
