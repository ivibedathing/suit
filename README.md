<p align="center">
  <img src="design/app-icon.png" width="128" alt="Suit app icon">
</p>

# Suit — Stop Using IDE Terminal

A personal macOS app growing from a terminal into a Claude-code-first cockpit for monorepo
work. It's a native app bundle (Dock icon, own bundle identifier, own TCC permission entries)
whose windows host browser-style tabs of terminals, file viewers, diffs and Claude transcripts,
each shell running directly over a real pty
([SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)).

![Suit window: pinned terminal, shell and file viewer split](design/phase15-window.png)

## Features

### Tabs & panes — the browser model

- **Tabs first** — every terminal, file, diff and transcript is a tab in the strip below the
  title bar: ⌘T new shell, ⌘W close, ⇧⌘T reopen, ⌘1–9 jump (⌘9 = last), ⌃Tab for a
  most-recently-used switcher (hold ⌃ to pick, quick tap to toggle the last two). Pin tabs to
  compact icon-only slots; drag tabs to reorder, into another window to move them, or outside
  every window to tear off a new one.
- **Panes are viewports** — split screen shows a second tab beside the active one (⌘D takes the
  most recent background tab, or right-click a tab ▸ Split Screen, or drag a tab to a screen
  edge). Unsplit with ⌥⌘W, walk splits with ⌥⌘arrows. Closing a visible tab falls back to the
  most recent background tab; background tabs keep their processes running.
- **Exit status** — a clean shell exit closes its tab; a failure leaves it open with a red dot
  (hover for the signal/exit reason). Bells flash the pane, pulse a backgrounded tab's strip
  item, and bounce the Dock icon while the app is inactive.
- **State restoration** — quitting snapshots every window's tab list, split tree, and viewer
  scroll positions; the next launch reopens it all, restarting terminals as fresh shells in
  their old working directories.

### Files, search & navigation

- **Sidebar** (⌘B) — an icon rail with Files, Git, Bookmarks, SSH Hosts and Notes. The Files tree is
  gitignore-consistent with the file index, shows sub-project badges (`go.mod`,
  `package.json`, …) and git status letters, and can be pinned to any folder; a footer shows
  the current branch and the repo's branch/worktree counts.
- **Project search** (⇧⌘F) — live ripgrep search with regex/case toggles, a glob filter, and
  Project / Sub-project / Pane Directory scopes; results stream in grouped by file.
- **Open quickly** (⌘P) — fuzzy-find any file in the project index; ⌘K opens the command
  palette over every app command plus your prompt library.
- **File viewer** — files open as read-only tabs (deduped by path) with syntax highlighting, a
  minimap, line numbers, go-to-line (⌘L), and orange marks on lines changed since HEAD.
  Cmd-click a path in any terminal (with optional `:line`) to jump straight to it.
- **Blame gutter** — Toggle Blame (⌃⌘B) shows a per-line column of the last-touching commit
  (short sha + author, tinted by age) beside the line numbers; the full commit subject is on
  hover, and clicking a line's sha opens that commit's diff.
- **File history** — Show File History opens the Git tab's list of commits touching the open
  file (`git log --follow`) — sha, subject, author, age; click a commit to open its per-file
  diff.
- **Preview tabs** — the viewer routes by extension, so previewing a README or a design asset
  never means a trip to Finder. Markdown (`.md`/`.markdown`) renders formatted — headings,
  lists, blockquotes, fenced code (syntax-colored), and clickable links — with a Rendered ↔ Raw
  toggle. Images (PNG/JPG/GIF/SVG/…) open over a checkerboard backing with a zoom-to-fit /
  actual-size toggle and the pixel dimensions in the header. PDFs open in a PDFKit view with a
  page-thumbnail rail. All three are ordinary tabs, so split, drag, path-dedupe, and state
  restoration (scroll / zoom / page) work unchanged.
- **Bookmarks** — pin a specific `file:line` with ⇧⌘L (or click the gutter) — an amber tick
  shows in the viewer gutter and minimap. The Bookmarks sidebar tab lists them; Enter or
  double-click reopens the file at that line, right-click renames or removes. Saved in
  `~/.suit/bookmarks.json`, shared across windows, dead paths pruned automatically.
- **Diff view** — `git diff HEAD` as a tab (⌃⌘D), unified or side-by-side with scroll-locked
  halves; review mode walks changed files with n/p and opens the file under review with o.
  A commit ref (from a blame sha or a File History row) opens that commit's per-file diff.
- **Review comments → Claude** — in a diff, press `c` on a line to attach a review comment
  (GitHub-PR style); comments render inline in amber and collect into the pane's review draft.
  The header's **Review (N)** button lists them (edit / delete / open file), and **Send Review
  to Session…** (also in the palette) pipes the whole batch into a chosen Claude session as one
  structured prompt, then clears the draft. Comments persist across restarts with the diff tab.
- **Git tab** — the sidebar's Git rail shows staged / changed files (click to open the scoped
  diff) and, below them, a **Branches** list: every local branch with its ahead/behind vs
  upstream (green ↑ / amber ↓), a worktree glyph, and a dirty dot; the current branch is
  highlighted. Click a branch to check it out (or switch the sidebar to its worktree).
- **Branch → PR** — right-click a branch for gh actions: **Create PR…** (title prefilled from
  the branch, body from its commits), **Open on GitHub**, and **Checkout**. When a PR exists it
  shows a `#N` badge with a ✓/✕/• checks glyph. Everything degrades gracefully without the `gh`
  CLI — the menu still checks out, and shows a hint to install gh.
- **Notes** — a free-text scratch tab in the sidebar backed by `~/.suit/notes.txt`;
  right-click a terminal selection to append it as a note.

### Claude Code cockpit

- **Session awareness** — an installer (app menu ▸ "Install Claude Code Integration…") wires
  Claude Code's statusline and hooks to `~/.suit`. Panes running Claude sessions show a state
  dot (busy / pulsing needs-input / done) and a context-fill %, the strip shows global 5h/7d
  usage, and the Sessions sidebar sorts sessions "needs you first".
- **Attention** — a session that needs input while Suit is inactive posts a notification
  (click to jump to its pane) and badges the Dock with the needs-input count.
- **Talk-back** — send prompts into any session's pty: quick actions (Prompt… / Continue /
  /compact / Interrupt), a floating composer with `@`-completion over repo files, a prompt
  library (`~/.suit/prompts/*.md`), or right-click ▸ "Send Selection to Claude Session" to pipe
  an error/diff/log line over with context.
- **Set as Goal** — select code or prose in a file viewer, transcript, or terminal, then
  right-click ▸ "Set as Goal" (or the palette's "Set Selection as Claude Goal") to send
  `/goal <selection>` into a chosen session — turning "this is what I want done" into a
  two-click gesture. Sent as one bracketed-paste unit (multi-line selections stay intact) and
  submitted; a session picker appears when several are live, defaulting to the last one you
  targeted. An optional setting prepends the source location (`From <file>:<lines>:`).
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
- **Worktree tasks** — "New Claude Task…" (⌃⌘T) creates a git worktree on a task branch and
  opens a pane running `claude` in it; finishing the task merges or discards the worktree.

### Autopilot

- **Autonomous roadmap execution** — Autopilot works through a project's `ROADMAP.md` on its
  own: whenever the token budget allows, it creates a git worktree for the next unshipped
  phase and opens a visible tab running `claude` in it; the worker implements the phase,
  builds, updates the docs, pushes, and opens a PR. Suit then gates the PR — `./build.sh` must
  exit 0 and a headless Claude review must approve — auto-merges it, cleans up the worktree,
  and loops to the next phase. Gate failures feed the build-log tail or review findings back
  into the live session for another attempt (capped by the Attempts setting); anything
  unrecoverable blocks Autopilot with a notification, keeping the worktree, branch, PR and
  logs for inspection (the palette's Retry resumes). One run at a time; merged phases post a
  notification too. Needs the `gh` CLI (installed and authenticated) and the Claude Code
  integration.
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
  merging PR #142`, `⚠ Phase 23 blocked — …`. Clicking it focuses the run tab while a run is
  active, otherwise opens the log; the tooltip carries the full reason.
- **Palette commands** — `Autopilot: Enable`/`Disable` (the title flips) and `Autopilot: Show
  Log` are always there; while enabled, also `Run Next Phase Now` (bypasses the budget gate
  once), `Pause After Current Run`/`Resume`, `Skip Current Phase`, and `Open Run Tab`, plus
  `Retry` while blocked. No new keyboard bindings — palette-reachable is keyboard-complete.
- **The run tab** — the worker is an ordinary terminal tab titled `⚙ Phase N — <Title>`,
  opened without stealing focus; watch it, split it, or type into it (the session dot pulses
  on needs-input as usual). A worker exit never auto-closes the tab, so the scrollback
  survives for debugging.
- **Steering = editing ROADMAP.md** — phase priority is document order; `✅` anywhere in a
  phase heading means shipped, `⏸` means skipped ("Skip Current Phase" appends it — the
  engine's one write to the file). When every phase is shipped or skipped, Autopilot idles
  until the roadmap changes again.
- **On disk** — `~/.suit/autopilot/` holds `state.json` (the current run — it survives a
  relaunch, and Autopilot resumes it at the right stage), `history.jsonl` (one row per
  finished run: outcome, PR URL, attempts, cost), `autopilot.log` (the human-readable event
  log Show Log opens as a viewer tab), and `logs/<slug>/build-N.log` / `review-N.log` (gate
  output). A `~/.suit/autopilot-prompt.md`, when present, overrides the worker prompt
  template.

### Appearance & settings

- **Settings** (⌘,) — a sectioned defaults form: font and default size, text color, default
  pane background, opacity (⌘] / ⌘[) and blur (⇧⌘B); the shell new tabs run, cursor shape and
  blinking, bell responses (pane flash, Dock bounce); word wrap for file viewers; Claude
  session arguments and whether "Set as Goal" prepends the source location. Everything
  persists across launches.
- **Per-pane looks** — right-click a pane for background presets (Midnight, Dracula, Nord,
  Solarized Dark, …) or a custom color, per-pane font size (⌘= / ⌘-), and a decorative ASCII
  screensaver overlay (waves/stars) with its own colors and speed.

### Safety

- **Paste safety** — pasting multi-line text or `curl`/`wget`-into-a-shell one-liners prompts
  with a preview of exactly what's about to be sent.
- **Clipboard hygiene** — OSC 52 "copy to clipboard" from remote/tmux sessions works, but
  OSC 52 *read* queries are denied outright, so nothing in a pane can silently read your
  clipboard.
- **Login shells** — shells start login+interactive (`-l -i`), so `~/.zprofile` PATH setup
  (Homebrew) and `~/.zshrc` (Powerlevel10k, oh-my-zsh) load the same as in Terminal.app.

## Keyboard shortcuts

The full list also lives in-app under **Settings (⌘,) ▸ Shortcuts**.

### Tabs

| Shortcut | Action |
| --- | --- |
| ⌘T | New tab |
| ⌘W | Close tab |
| ⇧⌘T | Reopen closed tab |
| ⇧⌘] | Next tab |
| ⇧⌘[ | Previous tab |
| ⌃Tab | Cycle recent tabs (MRU) |
| ⌃⇧Tab | Cycle recent tabs (back) |
| ⌘1…⌘8 | Go to tab 1–8 |
| ⌘9 | Go to last tab |

### Screens & splits

| Shortcut | Action |
| --- | --- |
| ⌘D | Split screen with new terminal |
| ⇧⌘D | Split screen horizontally (stacked) |
| ⌥⌘W | Unsplit (keep tab) |
| ⌃⌘M | Unsplit all |
| ⌥⌘← / → / ↑ / ↓ | Focus split left / right / above / below |

### Files, search & navigation

| Shortcut | Action |
| --- | --- |
| ⌘P | Open quickly (fuzzy file finder) |
| ⌘K | Command palette |
| ⌘B | Toggle sidebar |
| ⇧⌘F | Search in project |
| ⌘F | Find in pane |
| ⌘G | Find next |
| ⇧⌘G | Find previous |
| ⌘E | Use selection for find |
| ⌘L | Go to line (file viewer) |
| ⇧⌘L | Toggle bookmark on the current line (file viewer) |

### Git & Claude

| Shortcut | Action |
| --- | --- |
| ⌃⌘D | Show git diff |
| ⌃⌘B | Toggle blame gutter (file viewer) |
| ⌃⌘C | New Claude session |
| ⌃⌘T | New Claude task |
| ⌃⌘F | Search transcripts |

Show File History (palette / viewer right-click) lists the open file's commits in the Git tab.

In a focused diff pane, `n` / `p` walk the changed files, `o` opens the file under review, and
`c` adds a review comment on the line at the caret (batched to a Claude session with Send
Review to Session…).

### Appearance

| Shortcut | Action |
| --- | --- |
| ⌘= / ⌘- | Increase / decrease font size |
| ⇧⌘= / ⇧⌘- | Increase / decrease font size (all panes) |
| ⌘] / ⌘[ | Increase / decrease opacity |
| ⇧⌘B | Toggle background blur |

### App & windows

| Shortcut | Action |
| --- | --- |
| ⌘N | New window |
| ⌘, | Settings |
| ⌘C / ⌘V | Copy / paste |
| ⌘Q | Quit Suit |

## Build & run

```
./build.sh                        # builds swift/, assembles build/Suit.app
open build/Suit.app               # launch like a normal Mac app
```

See `CLAUDE.md` for the full architecture breakdown, dev-loop details, and why this project
avoids SwiftPM. `ROADMAP.md` has the phased plan this grew through.

## Requirements

- macOS 14+
- Xcode Command Line Tools (`swiftc`) — no full Xcode or SwiftPM required
