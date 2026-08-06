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
- [Appearance & settings](#appearance--settings)
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
  (⌘D / ⇧⌘D open a fresh terminal there, or right-click a tab ▸ Split Screen, or drag a tab
  to a screen edge); the split-out tab becomes the new pane's own. Unsplit with ⌥⌘W (its tabs
  fold back into a neighbor), walk splits with ⌥⌘arrows. Closing the active tab falls back to
  another tab the same pane owns; background tabs keep their processes running.
- **⌘D splits look like the pane they came from** — the new terminal starts in the focused
  terminal's working directory *and* wears its background color, so a pane recolored from the
  title bar's Background Color menu splits into a matching pair instead of snapping back to the
  global default. Splitting off a non-terminal pane (a viewer, diff, transcript) still gives the
  new shell the normal terminal background — a viewer's chrome ground would leave the shell
  unreadable.
- **Drag a tab into its own pane** — grab a chip from a pane's in-pane tab bar and drag it onto
  any viewport; it shows the same split-zone preview a pane drag does: drop on an outer half
  (left / right / top / bottom) to split it out into its own new pane on that edge, or drop on
  the center or the header to just show it in that pane (the displaced tab backgrounds, its
  process untouched). The tab previews as a pane header while you drag, so it's clear it can
  become a pane. Drag a chip clear of every window to tear it off into a new window of its own.
- **Type into a shell that is still starting** — a new tab's `zsh -l -i` can take a second to
  reach its line editor, and a Powerlevel10k instant prompt paints a prompt long before then and
  runs `stty -icanon` while leaving echo on. Type into that gap and the kernel echoes bytes with
  nothing editing them, so backspace arrives as literal `^?` (`~/Pr/suit ❯ echo hi^?^?^?`). Suit
  holds those keystrokes instead, draws them itself — backspace erasing properly — and hands the
  finished line to the shell the moment its line editor takes over, which renders it for real.
  The hold is scoped to exactly that state: while the tty is still canonical the driver already
  behaves, and the moment echo goes off (zle, a password prompt, a full-screen app) input passes
  straight through. ^C keeps its signal throughout, and a shell that never reaches a line editor
  releases the keystrokes after ten seconds.
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
  sidebar's tabs: Files, Search, Source Control, Sessions, SSH Hosts and Notes, top to bottom. It
  stays put when the sidebar is collapsed, so clicking any icon reopens the sidebar on that tab.
  Clicking the icon of the tab you're already on collapses the sidebar again (as ⌘B does). The
  Source Control icon carries a count badge of the changed files in the shown repo, so a dirty
  tree is visible with the sidebar closed.
- **Sidebar** (⌘B) — the panel beside the activity bar, showing the selected tab. Every tab opens
  with its own title — FILES, SEARCH, SOURCE CONTROL, SESSIONS, SSH HOSTS, NOTES, BOOKMARKS —
  since the activity bar itself shows icons only; the title row also carries that tab's header
  actions (the Files header's buttons, Search's toolbar, the + on Notes and SSH Hosts), and it
  follows a live theme switch. That row starts flush with the panel's top edge — it is the margin,
  so no blank band sits above it — and the activity bar's first icon starts on the same line.
- **Files tab** — leads with a single project header: the title row's search / choose-folder /
  unpin actions, the folder name below it (a pin glyph when pinned), and, inside a repo, a branch
  row carrying the branch switcher, the upstream sync badge and the git actions menu — then gives
  the rest of the tab to the tree. The tree shows sub-project badges (`go.mod`, `package.json`,
  …) and git status letters, and can be pinned to any folder.
- **Click to select, double-click to open beside** — a single click on a file only selects it (on a
  folder it expands or collapses); a double-click opens the file in a **pane of its own** next to
  the active one, side-by-side when the pane is wide enough and stacked when it's tall. Reading a
  second file therefore never buries the first. Files stay deduped by path, so double-clicking one
  that's already open focuses the pane it's already in rather than splitting again, and a window
  with no room left to split falls back to opening it in the active pane. New File… still opens
  what you just created in the active pane.
- **Git status as colour** — inside a repo each filename is tinted by its own status: green for
  added or untracked, amber for modified or renamed, red for deleted, grey for gitignored, plain
  text for clean. The colours are the same palette tokens as the status letter beside them, so
  they stay legible under every theme and follow a live theme switch. Folders keep the plain
  colour and their amber dot for "something under here changed".
- **Ignored files are shown, not hidden** — gitignored rows appear greyed out rather than missing.
  A wholly-ignored folder (`build/`, `node_modules/`) arrives as a single collapsed row and is
  read off disk only when you expand it, so the tree can show you what's there without ⌘P or
  project search ever matching it — those still index tracked and untracked files only.
- **Dotfiles** — hidden folders and dotfiles
  (`.claude`, `.github`, `.gitignore`) are shown like any other row — inside a repo because
  `git ls-files` reports them, outside one because the fallback walk indexes them too, pruning
  only noise (`.git`, `.Trash`, `node_modules`, `.DS_Store`).
- **Project search** (⇧⌘F, the activity bar's magnifier, or the Files header's magnifier) — its own
  sidebar tab directly below Files, so searching never costs you sight of the file tree and your
  matches are still there when you come back to it. Live ripgrep, laid out like VS Code's search
  panel: **Aa** (match case), **ab** (match whole word, `rg -w`) and **.\*** (regular expression)
  sit *inside* the pattern field, and the chevron in the left gutter folds the replacement row
  away. **⋯** below the fields holds the glob filter and the Project / Sub-project / Pane
  Directory scope, and glows amber whenever one of them is shaping results while hidden. Results
  stream in grouped by file — name, path and match count, with the Files tree's type icon — and
  clicking a match opens it in the viewer at that line.
  **Esc** clears the pattern; **Esc** on an already-empty field hands the sidebar back to Files.
- **Search toolbar** — the header carries **Refresh** (re-run without retyping), **Clear**,
  **View as List / Tree** (one flat row per match, each naming its file, versus the file tree) and
  **Collapse All / Expand All**. Hovering a file row swaps its match count for two actions:
  **Replace All in File**, and **✕** to drop that file from the results — Replace All then only
  touches what is still listed, so you can prune the noise before committing to a rewrite.
- **Search hits are highlighted in the file** — while the Search tab holds a pattern, every open
  text viewer washes each occurrence of it in yellow and ticks the lines carrying one down the
  right-hand lane of its minimap, so "where else is this in the file" is answered without going
  back to the results list. It applies to every open viewer in that window, not only the file you
  clicked through to, and to files opened afterwards; the regex, case and whole-word toggles carry
  over, so what a pane highlights is exactly what the list matched. Clearing the pattern (**Esc**,
  or the header's Clear button) takes the wash and the ticks away. The ⌘F bar still paints over
  it — its current match stays the
  strongest mark on screen — and editing a file re-derives the hits as you type.
- **Project-wide replace** — the Search tab's second row: type a replacement and **Replace All**
  (or Enter in that field) rewrites every listed match. It confirms first, with the file and match
  counts, because it edits files that aren't open in any pane and there's no ⌘Z waiting for those.
  **AB** in the replacement field preserves case: a match spelled `Widget` or `WIDGET` takes the
  replacement capitalized or upper-cased to match. It only ever raises case, never lowers it, so a
  deliberately-cased replacement (`onKeyDown`) survives a lowercase match intact.
  Regex mode interpolates capture groups (`$1`) exactly as the viewer's ⌘F bar does, and an empty
  replacement deletes the matches. Each file is rewritten atomically — the same writer ⌘S uses —
  and the results re-run afterwards so the list reflects what's now on disk. Two deliberate
  refusals: it won't run while the search is still streaming, and it won't run on a result set that
  hit ripgrep's 2,000-match cap, since replacing a partial list would silently leave the rest of the
  repo behind (narrow the scope or add a glob). Files that stopped matching, can't be read as UTF-8
  text, or fail to write are reported in the status line rather than skipped in silence.
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
- **Notes** — plain `.txt` files in `~/.suit/notes/`, listed in the sidebar's Notes tab. Clicking a
  row (or **Return**) opens the note as an ordinary file tab, so it edits exactly like a project
  file: autosave, ⌘S, undo, ⌘F find/replace, line numbers, split and drag, restored at the next
  launch. The filename is the title. **+** asks for a title and opens the new note; right-click a
  row for **Open**, **Rename…**, **Reveal in Finder** or **Move to Trash**. Right-clicking a
  terminal selection captures it as a new note (titled after its first line) and opens it. Notes
  kept in the older `notes.json` / `notes.txt` are imported into the directory once, at first
  launch, and the originals are left on disk untouched.
- **Background** — the sidebar's last tab (also **View ▸ Show Background Tasks**, or "Show
  Background Tasks" in the palette): a live log of the work *Suit itself* does when nobody asked.
  Every internal `git` and `gh` call, project-index rescan, ctags pass, ripgrep run, `lsof` poll
  and update check lands here with what ran, what triggered it (`file change`,
  `tab shown`, `ref change`, `project opened`, `timer`, `user`, `coalesced`), how long it took, and
  how it ended. Rows are grouped by subsystem glyph and tinted red on failure; a run of identical
  operations collapses to one row with a **×N** and the run's total time, so an FSEvents burst
  reads as `git status ×6 · 720ms` rather than six rows. The footer keeps a rolling
  "N runs · time · failures in 1m" — the line that makes a runaway cascade obvious at a glance.
  The kind popup filters to one subsystem (remembered across launches), **⏸** stops recording
  without clearing what's there, and **🗑** empties the log. Read-only: rows aren't clickable, but
  each carries its full record as a tooltip. The log is the last 800 operations, in memory only —
  it is deliberately never written to disk, since appending every `git status` to a file would
  recreate exactly the churn the tab exists to expose — so it starts empty at each launch. A
  routine probe ("is this a git repo", "does `main` exist") answering *no* logs as an ordinary
  empty result, not a failure.

### File viewer & navigation

- **File viewer** — files open as tabs (deduped by path) with syntax highlighting, a
  minimap, line numbers, go-to-line (⌘L), and orange marks on lines changed since HEAD.
  Cmd-click a path in any terminal (with optional `:line`) to jump straight to it. Files are
  first-class tabs: every open (sidebar click, ⌘P, search hit, Cmd-click link) opens the
  file's own tab or re-activates it if the path is already open — files never load one on top
  of another, so opening three files leaves three tabs.
- **Syntax highlighting** — colour arrives from a bundled scanner (no language server, no
  download) covering ~40 languages: Swift, Go, C/C++/Objective-C, Rust, Zig, Java, Kotlin,
  Scala, Groovy/Gradle, C#, Dart, JavaScript/TypeScript, Python, Ruby, PHP, Perl, Lua, R,
  Elixir, Haskell, PowerShell, shell, SQL, and the config/markup family — HTML, XML/SVG/plist,
  CSS, SCSS/Sass/Less, JSON, YAML, TOML, INI, Markdown, GraphQL, Protobuf, Terraform/HCL,
  Makefile, and Dockerfile. Extensionless files that carry real syntax are recognised by name
  (`Makefile`, `Dockerfile`, `Gemfile`, `Rakefile`, `.zshrc`, `.gitconfig`). HTML understands
  tags, attributes and entities, and hands embedded `<script>` and `<style>` bodies to the
  JavaScript and CSS scanners, so a single-file page is coloured throughout; style sheets
  distinguish a selector from a declaration, so `color` reads as an element in one place and a
  property in the other. The scan runs off the main thread and skips files over 2 MB, which
  render as plain text.
- **Edit files** — the viewer is editable: type into the buffer (undo with ⌘Z) and it
  **autosaves** to disk on a short debounce, or save now with **⌘S** (File ▸ Save / palette
  "Save File"). An accent dot on the tab (in place of its close ✕ until you hover) and in the
  pane header marks unsaved edits; pending edits also flush when you close the tab or quit.
  Binary, over-8 MB, and unreadable files stay read-only. Editing stays a deliberate, bounded
  slice — Suit is still viewer-first, with Claude doing the heavy code-writing. macOS's typing
  substitutions are off in the editor: a quote stays straight, `--` stays two hyphens, and neither
  the replacement table nor autocorrect fires — `"hi"` is a string literal and `“hi”` is a syntax
  error, so what you typed is what lands in the file.
- **New file (⌘N)** — opens an empty document called **Untitled-1** in a viewport of its own,
  beside the pane you were in, with the caret already in it: the editor twin of ⌘D, which does
  the same for a shell. (New Window moved to **⇧⌘N** to free the key.) Nothing is written to disk
  yet — the tab *is* the document, so a thought that goes nowhere leaves no empty file behind.
  The first **⌘S** asks where it should live, opening in the window's current directory and
  offering the Untitled name; once saved it becomes an ordinary file tab, and syntax highlighting,
  autosave, the git gutter and the outside-change watcher all start working from the extension you
  chose. The number is the lowest free one, so closing Untitled-2 and pressing ⌘N again gives
  Untitled-2 back rather than climbing forever. Saving onto a file the window already has open
  keeps the one-tab-per-file rule: the scratch tab gives way to the established one, which owns
  that file's scroll, folds and bookmarks, and which reloads to show what was just written — or
  asks first, if you had unsaved edits there. Because an unsaved scratch buffer is the one thing
  here that no autosave can recover, closing its tab, its window, or quitting asks first when you
  have typed something into it.
- **The standard editing commands** — **⌘Z** / **⇧⌘Z** undo and redo, **⌘X** / **⌘C** / **⌘V** cut,
  copy and paste, **⌘A** selects all, and right-clicking the text offers the same four. They live
  in the Edit menu and route through the responder chain, so they follow the focus: the file
  viewer, a terminal's scrollback (⌘A selects it, ⌘C copies the selection), the commit box, or a
  find field. One exception: a terminal whose program negotiated the kitty keyboard protocol gets
  ⌘Z / ⇧⌘Z / ⌘X / ⌘A delivered as super-modified keys instead — that negotiation is a request for
  exactly those chords — while ⌘C / ⌘V stay with the clipboard.
- **Home and End move the caret**, not the scroll position — to the start and end of the line the
  caret is on, wrapped lines included. Home is *sticky about indentation*: it lands on the line's
  first non-whitespace character, and pressing it again goes to the true column zero (and again
  back to the text), so an indented line's text is one keystroke away. **⇧Home** / **⇧End** extend
  the selection, and **⌘Home** / **⌘End** keep the jump-to-the-file's-ends meaning that the bare
  keys have on stock macOS.
- **Smart typing** — the editor knows the shape of code. **Return** auto-indents to the enclosing
  block (and opens a body between a just-typed `{`/`}` pair); brackets and quotes **auto-close**,
  with type-over when you type the closer yourself, wrap-the-selection when text is selected, and
  pair-delete when Backspace lands between an empty pair. **⌘/** toggles line comments for the
  selection (using the language's own comment token, and un-commenting only when *every* selected
  line is already commented), **⌃⌘]** / **⌃⌘[** indent and outdent. Anything the editor doesn't
  positively recognise is handed back to the text view untouched, so IME, dictation and paste
  behave exactly as before.
- **Multi-selection** — **⌃⌘E** adds the next occurrence of the selection to the selection set,
  **⌃⌘G** selects every occurrence at once, and **⌥-drag** makes a rectangular (column)
  selection. Operations then apply to *all* of them as **one undo step**: comment (⌘/), indent
  and outdent (⌃⌘] / ⌃⌘[), wrapping the selection in brackets or quotes, and delete. Esc
  collapses back to one.

  It is deliberately **multi-selection, not multi-cursor**: free-form typing across several
  sites isn't supported, and typing over a multi-selection beeps rather than editing some of the
  sites and not others. The reason is AppKit — `NSTextView` collapses a selection made purely of
  zero-width carets down to one, so "a caret at each site" cannot be represented, and a
  half-working version of it would silently mangle a file that autosaves. (⌘D stays Split
  Screen, and ⌥⌘D is macOS's own Dock-hiding shortcut, which is why neither is used here.)
- **Code folding** — chevrons in the gutter fold the block they sit on; **⌥⌘[** / **⌥⌘]** fold and
  unfold the block around the caret, **⌥⌘0** / **⇧⌥⌘0** fold and unfold everything. Braced
  languages fold on bracket nesting and indentation-based ones (Python, YAML, Markdown) on
  indentation. Folds are remembered by the line that opens the block, so they survive edits above
  them and re-renders, and a fold whose block no longer exists simply disappears rather than
  hiding the wrong lines.
- **Symbol outline & breadcrumbs** — **⌃⌘O** opens this file's symbols as a picker, indented by
  nesting depth (⇧⌘O is Show Fleet, so the in-file picker takes ⌃⌘O). Above the text, a
  **breadcrumb strip** shows where the caret is — `File.swift › TabStore › activate()` — and each
  crumb is clickable, jumping to that symbol's declaration. Both read the ctags index
  go-to-definition already maintains, so they cost no extra parse and can never disagree with a
  jump.
- **Peek Definition** — **⌥⌘J** (or ⌥⌘-click, or the right-click menu) answers "what is this?"
  without leaving your place: the definition's source appears in a small syntax-coloured popover
  floated near the caret. **Esc** dismisses it; **Return** promotes it to a real jump for the times
  the answer was "I need to be there". It resolves through the same symbol lookup as
  go-to-definition, so peek and jump always agree.
- **Navigation history** — **⌃-** goes back and **⌃⇧-** forward through symbol jumps, the way a
  browser does: going back doesn't discard anything, so forward still works, and jumping somewhere
  new from mid-history truncates the forward tail. Each window keeps its own history, and a
  location is recorded before every navigating jump — so chasing a definition four levels deep and
  walking back out is one keystroke per level.
- **Live reload on outside changes** — open tabs track their file on disk. When something else
  rewrites it — Claude editing the file you're reading, `$EDITOR`, a branch switch, a build
  regenerating an asset — the tab updates within a fraction of a second, no click or refocus
  needed. In the viewer a **clean buffer silently reloads**, keeping your scroll position, and
  one with **unsaved edits asks** whether to keep your edits (your next save wins) or reload
  from disk; only one such prompt is ever up at a time, however many writes land while you
  decide. Markdown, image and PDF tabs re-render in place, holding your scroll position, your
  `<details>` toggles, and your PDF page. A time-travel scrubber is never reloaded over.
  Deleted files keep showing their last content rather than blanking, and pick the change back
  up when the file returns — a `git checkout` that removes and rewrites a file lands correctly.
  (A file that stays missing for more than ~45 seconds stops being watched: the viewer still
  catches up the next time Suit regains focus, but a markdown, image or PDF tab needs
  reopening.) Bursts of writes
  coalesce into one reload, so a generator writing in chunks costs one re-render, not one per
  chunk.
- **Blame gutter** — Toggle Blame (⌃⌘B) shows a per-line column of the last-touching commit
  (short sha + author, tinted by age) beside the line numbers; the full commit subject is on
  hover, and clicking a line's sha opens that commit's diff.
- **File history** — Show File History opens the Source Control tab's list of commits touching the open
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
- **Commit graph** — **Show Commit Graph** (the Source Control tab's graph button, or the command palette)
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
  find pasteboard, so a query carries between panes and from other apps. Stepping moves the wash
  and the scroll but deliberately leaves the text selection where it was — macOS greys a selection
  out whenever the text view isn't focused, which it never is while the bar is up, and that grey
  would paint over the very match you are standing on. Esc closes, selects the match you landed on,
  and hands focus back to the text. Find works everywhere — including read-only buffers like a time-travel revision
  or a binary placeholder — but replace disables itself wherever the buffer can't be written, so it
  can never fail at save time instead of up front. Terminals keep SwiftTerm's own find bar on the
  same ⌘F.
- **Go to definition & find references** — Cmd-click an identifier in the viewer (or Go to
  Definition, ⌃⌘J) to jump to where it's defined; several definitions open a palette picker,
  each `file:line` with its kind. Find References (⌃⌘R) opens a references pane listing every
  use of the symbol, grouped by file, each row a click into the viewer at that line. Both are on
  the viewer's right-click menu too — except in a file with no language (a note, a `.txt` log),
  where ctags has nothing to say and the symbol entries are left out of the menu rather than shown
  dead. A bundled `universal-ctags` builds the symbol index per git
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
  shows in the viewer gutter and minimap. The palette's **Show Bookmarks** opens the sidebar's
  bookmarks list (it has no activity-bar icon); Enter or
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
  (hover it for the repo's branch/worktree counts); click the branch name to drop a switcher menu
  of the repo's
  **worktrees** (pick one to repoint the whole sidebar there) and **local branches** (pick one to
  check it out). Picking a worktree also **walks the open terminals over** to it: every visible
  shell sitting idle at a prompt inside the repo's worktree tree gets `cd`'d to the matching spot
  under the new worktree (same relative subpath when it exists there, otherwise the worktree root),
  so the terminal you're looking at actually lands on the new branch. Terminals mid-job (running
  `claude`, a build, `vim`) are left alone.
- **Branch git actions** — the same branch row ends in a **⋯** menu that runs the everyday git
  commands against the shown repo, without dropping to a terminal: **Fetch** (with `--prune`),
  **Pull** (fast-forward only, so a diverged branch fails loudly instead of quietly merging),
  **Pull (Rebase)**, **Push** — or **Publish Branch** when the branch has no upstream yet —
  **Stash Changes** (untracked files included), **Pop Stash (N)**, **Discard All Changes…**,
  **New Branch…** and **Delete Branch ▸**. Entries that couldn't succeed are disabled rather than
  hidden (Stash with a clean tree, Pop with an empty stash), and the delete submenu only lists
  branches git would actually let go — never the checked-out one, never one another worktree
  holds. Everything runs off the main thread, so a slow fetch never freezes the window, and the
  branch row repaints as soon as it lands.
- **The destructive ones ask first** — **Discard All Changes** (`reset --hard` + `clean -fd`) and
  force-deleting an unmerged branch put up a confirmation naming what's about to be lost. The
  confirm button gives up its Return key, so a reflexive Return does nothing and the only way
  through is to click it; **Esc** cancels. Nothing in the
  menu force-pushes or rewrites pushed history. Deleting an unmerged branch fails safely first
  and *then* offers to force it, so the warning appears exactly when it's true. New branch names
  are checked against git's ref rules before a process is spent on them.
- **Diff vs the remote** — when the branch is ahead of or behind its upstream, the branch row
  shows an amber **↑2 ↓1** badge (**gone** in red when the remote branch was deleted, **no
  remote** when it was never pushed). Click it — or **Diff vs origin/…** in the ⋯ menu — to open
  the local↔remote diff in the window's diff tab, with the full review surface (comments, ⌘F,
  Refresh) available on it. The diff is taken against the merge base (`origin/main...main`), so a
  branch that's both ahead and behind reads as *your work* rather than as reversed upstream
  commits. The counts come from the last fetch, not the network — **Fetch** refreshes them.
- **Source Control tab** (⌃⌘G, the activity bar's branch icon, or **Show Source Control** in the
  palette) — the whole local git loop in the sidebar. Top to bottom: the tab title, a **branch row** (the
  worktree/branch switcher, plus the ⚑ marker, ± full-diff and commit-graph buttons), a **sync
  row** (the upstream badge and a ⋯ actions menu — the same fetch/pull/push/stash/branches set the
  Files header offers), the **commit box**, and then the file list: **Staged** and **Changes**
  sections (click a file to open its scoped diff; untracked files open in the viewer) followed by
  a **Branches** list — every local branch with a remote cloud, its ahead/behind vs upstream
  (green ↑ / amber ↓), a worktree glyph, and a dirty dot, the current one highlighted. Click a
  branch to check it out (or switch the sidebar to its worktree).
- **When the tab refreshes** — the working-tree half (the Staged/Changes rows and the activity
  bar's count badge) follows the repo and stays right even while the tab is hidden. The half that
  shells out — the branch list, the feedback gather, and the `gh` PR/review-inbox passes — runs
  only when something happened that could have changed it: the tab was revealed, the shown repo or
  branch changed, or you ran an action here (commit, push, create PR, submit a review). There is no
  polling and no refresh interval. That matters when several sessions work different worktrees at
  once: previously every file a build or an agent wrote re-ran the whole set, which kept `gh`
  network calls permanently in flight. If PR data looks stale, switch away and back, or use the ⋯
  actions menu — both re-list it.
- **Is this branch on the remote?** — each branch row carries a cloud: **filled** when a remote has
  it, **hollow** when it has only ever lived here, and a **red struck-through** cloud when the
  upstream it tracks is gone (merged and deleted on the remote, say). The answer comes from the
  remote-tracking refs rather than from tracking config, so a branch that was pushed without `-u`
  — or arrived with a clone — still reads as published. Like git's own `gone` marker it's a local
  view: fetch to refresh it. Hover the row for the state in words.
- **Staging** — every file row ends in a **+** (stage) or **−** (unstage), and each section header
  has the bulk twin: **+** on Changes stages everything (`add -A`, untracked files included), **−**
  on Staged empties the index with a mixed reset, so nothing on disk moves. Right-click a row for
  **Stage / Unstage Changes**, **Discard Changes…**, **Open Diff** and **Open File**. Discard is
  offered on the working-tree column only — unstage first — and asks before it runs, because it
  restores tracked files and *deletes* untracked ones.
- **Committing** — type a message in the box (⌘↩ commits without touching the mouse; **Commit
  Changes…** in the palette jumps straight there) and press the button. It says what it will do:
  **Commit 3** with three files staged, **Commit All 5** when nothing is staged — in which case
  committing stages everything first, rather than quietly committing nothing. The ▾ beside it
  holds **Commit Staged**, **Stage All & Commit**, **Commit & Push**, **Amend Last Commit** (a
  toggle: it pulls the previous message into the box, and an empty box keeps that message
  unchanged), and the bulk stage/unstage entries. The message box only clears once the commit has
  actually landed, so a rejected pre-commit hook doesn't cost you what you typed. Nothing here
  force-pushes: amending something already pushed fails at the push, loudly.
- **A bigger message box** — the grip between the message and the Commit button (the pointer turns
  into a resize cursor over it) drags the box taller, up to 320pt, and back down to its two-line
  default; the file list moves with it. The height is remembered across launches, and a short
  window overrides it rather than squeezing the file list below ~90pt. The box never resizes on
  its own while you type — a box that grew with the text would move the file list under the
  pointer mid-edit.
- **Branch → PR** — right-click a branch for gh actions: **Create PR…** (title prefilled from
  the branch, body from its commits), **Open on GitHub**, and **Checkout**. When a PR exists it
  shows a `#N` badge with a ✓/✕/• checks glyph. Everything degrades gracefully without the `gh`
  CLI — the menu still checks out, and shows a hint to install gh.
- **Delete a branch** — the same right-click menu ends in **Delete Branch**, the safe `git branch
  -d`: an unmerged branch fails first and *then* offers to force it, so the warning only appears
  when it's true. The current branch has no entry, and one another worktree holds is shown
  disabled naming that worktree — git refuses either, and saying so beats hiding the action. Only
  the local branch goes; the remote is untouched.
- **"What changed while I was away"** — start Claude sessions across a repo's worktrees, step
  away, and come back to *one* diff of everything that moved. The Source Control tab's ⚑ button (or the
  palette's **Mark Now**) records a per-repo checkpoint — every worktree's HEAD plus a timestamp,
  in `~/.suit/markers.json`; the flag fills once a mark is set. **What Changed Since Mark**
  (⚑ menu or palette) then composes an aggregate diff across *all* the repo's worktrees — each
  worktree's commits, staged, unstaged, and newly-created files since the mark — into one review
  set in the diff tab, walkable with the usual `n`/`p`/`o`/`c`. A summary header leads it:
  files-touched and `+ins −del` per worktree, and which Claude session (matched by cwd) is
  working there, so the catch-up reads as "session X changed these 6 files". Worktrees created
  after the mark diff from their merge-base, so only their new work shows.
- **Feedback inbox** — a **Feedback** section at the top of the Source Control tab surfaces machine feedback
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
- **PR review inbox** — a **PR Review Inbox** section in the Source Control tab lists open PRs that involve
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
- **Usage color ramp** — each usage row's percentage and fill bar ride a continuous gradient from
  the theme's done green at 0%, through its busy amber at 50%, to its failed red at 100%, so a
  limit you're drifting toward shifts color the whole way up instead of jumping at a threshold.
  The ramp interpolates the active palette's own session colors, so it follows a theme switch.
- **Attention** — a session that needs input while Suit is inactive posts a notification
  (click to jump to its pane) and badges the Dock with the needs-input count. Additionally,
  Suit plays a macOS system sound when a Claude session finishes a task and a different one
  when it needs input / asks a question; sounds play only while Suit is in the background
  (no sound when it's the active app). Each event has its own on/off toggle and its own
  sound picker in Settings ▸ Claude; defaults are Glass (finished) and Ping (question), both on,
  and picking a sound previews it.
- **Dictation (speech to text)** — hold **🌐 (Globe / Fn) + V** to talk; release either key and the
  transcribed text drops into the focused pane's prompt (it is *not* auto-submitted, so you can
  review and edit before Enter). The V keypress is swallowed, so it never lands in the pane.
  A small "Listening…" HUD shows the live transcription. Recognition
  is **on-device** (Apple's Speech framework) — no network, no API key, works offline. First use
  prompts for microphone and speech-recognition access. **Dictate…** in the command palette (and
  View menu) primes that permission and reminds you of the gesture. Holding 🌐 on its own does
  nothing in Suit and keeps whatever *System Settings ▸ Keyboard ▸ Press 🌐 key to* is set to.

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
  input and CI failing — newest-first, each row a tone-colored glyph + title +
  repo · worktree/PR + relative age. Filter by repo or kind, and click a row to jump to the thing
  it names (the session's pane or the PR on GitHub). The events persist to
  `~/.suit/activity.jsonl` (append-only, so history outlives session-file pruning). A header
  shows a **"what happened today"** recap — sessions finished · PRs merged · CI failures — and
  once per day Suit delivers the previous day's digest as a notification (click it to open the
  feed).
- **Cost budget guardrails** — per-session and per-task (worktree) spend ceilings that watch each
  run's `cost_usd`. Set the defaults in Settings (⌘, ▸ Budget) as dollar caps (blank = off), or
  give one session its own ceiling with **Set Budget…** (right-click a fleet-dashboard row, or the
  "Set Session Budget…" palette command). When a session — or the summed spend of all sessions in
  a worktree — crosses its cap, Suit posts a notification (click it to focus the pane) and logs the
  trip to the activity feed; it never fires more than once per crossing. Tick **"Interrupt the run
  (Esc) when a cap is crossed"** to also send Esc into the offending pty and halt it — never
  silently.

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
  keystroke instead of a manual setup ritual. Manual and interactive (no gating or
  auto-merge).
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

## Appearance & settings

- **Hack ships with the app** — [Hack](https://sourcefoundry.org/hack) v3.003 (Regular, Bold,
  Italic, Bold Italic) is bundled in `Suit.app/Contents/Resources/fonts` and registered into the
  process at launch, so it's the default for terminals, file viewers, diffs, and transcripts on a
  machine where nothing was ever installed — and it shows up in the font picker whether or not you
  have it system-wide. Picking another font in **Settings ▸ Appearance** overrides it permanently:
  the first launch after Hack shipped moves you off the old system-monospaced default *once*, and
  never touches a font you chose yourself (including switching back to SF Mono). Chrome — sidebar
  labels, badges, line numbers — deliberately stays on the system monospaced font. Hack is MIT +
  Bitstream Vera licensed; the license ships alongside the TTFs.
- **Settings** (⌘,) — a category sidebar (macOS System-Settings style) with one pane per topic,
  so only the settings you're changing are on screen: **Appearance** (font and default size,
  text color, default pane background), **Terminal** (the shell
  new tabs run, cursor shape and blinking, bell responses — pane flash, Dock bounce),
  **File Viewer** (word wrap), **Claude** (session arguments, "Set as Goal" provenance, and
  notification sounds), **Themes** (swap the whole color palette — see below),
  **Budget**, and a read-only **Shortcuts** reference. Everything persists across launches.
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
  colors and speed. Terminals ground a step darker than the chrome: "Midnight" (#0A0C15 in Suit
  Dark — a blue-violet black that follows the active theme) is the default terminal background,
  giving shell output its own deeper layer, while "Slate" keeps the one-surface chrome ground
  (#17191D) available per pane. Past those two the presets are hued rather than grey, so splits
  are tellable apart at a glance: "Graphite" (#15171B) is the one neutral, then "Ink" (#0E1130),
  "Abyss" (#03202C), "Evergreen" (#08201A), "Deep Plum" (#1C0F2E), "Oxblood" (#230D14) and
  "Ember" (#21100A), with Dracula, Nord and Solarized Dark at their published values. All stay
  dark enough that dim ANSI text keeps its contrast. The same list backs the screensaver's
  background menu.
- **Section boundaries** — the chrome surfaces (activity bar, sidebar, pane headers, in-pane tab
  bars) deliberately share one ground, so every boundary between them is drawn as a hairline in
  the active theme's `hairline` token rather than left to a change of color: a full-height rule
  down the activity bar's right edge (its icons carry no rules between them — the hover square is
  already the cell boundary), themed split dividers between the sidebar and the pane tree and between every pair of panes (AppKit's system
  divider is derived from the appearance, not the palette, and vanishes on the darker themes), a
  rule under each pane header, and a rule between adjacent tabs in a pane's tab bar — skipped
  beside the active tab, whose own border already marks that edge. Everything follows a theme
  switch live.

## Themes

- **What a theme is** — a full set of Suit's 26 color tokens, in five groups: **Chrome** (window and
  terminal grounds, bar chrome, raised/hover surfaces, hairlines, overlays), **Text** (primary, dim,
  faint), **Accent & Status** (the accent plus the session busy / needs-input / done / failed
  colors), **Syntax** (keyword, string, comment, number, type, attribute, key), and **Diff** (added
  and removed text plus their two row washes). So a theme reaches past the chrome into the file
  viewer's code colors, the markdown code blocks, the minimap, the definition peek, the diff pane,
  and the commit graph's lane colors. Metrics (padding, sizes, corner radii) and fonts stay fixed, so
  a shared theme can recolor the app but never break its layout. A theme can be dark, light, or
  high-contrast — the window chrome is drawn from whichever palette is active.
- **Switching** — pick a theme from **Settings (⌘,) ▸ Themes**; clicking one applies it live and
  instantly, no relaunch. For quick cycling without opening Settings, run **Switch Theme…** from the
  command palette (⌘K), which labels each entry `built-in dark` / `custom light`. The selection
  persists across launches, so the app opens already themed. Fourteen themes ship built in:
  - **Suit originals** — **Suit Dark** (the default — the exact look you've always had),
    **Midnight** (navy over near-black, periwinkle accent), **Ember** (warm espresso, ember-orange
    accent), **Verdigris** (graphite with a verdigris accent — the quietest of the set),
    **Amethyst** (deep plum, violet accent), and **Obsidian** (true black for OLED, highest
    contrast).
  - **Familiar palettes** — **Nord**, **Dracula**, **Solarized Dark**, **Gruvbox**, **Tokyo Night**,
    and **Catppuccin Mocha**, at their published hues, with the chrome tokens Suit needs (a tab
    strip, a raised active tab, a hover state) filled in around them.
  - **Light** — **Suit Light** (neutral, re-contrasted with its own darker syntax set) and **Paper**
    (warm sepia for daylight).
- **What a theme switch moves, and what it doesn't** — the terminal ground and the terminal text
  color are separate user settings (**Settings ▸ Appearance**), so they survive a theme switch. Two
  exceptions keep light themes usable: a terminal ground that is still one of the two theme-derived
  presets ("Midnight" / "Slate" — i.e. you never picked a color) follows the new theme, and a text
  color the new ground would swallow (white on Paper's cream) is moved to the new theme's text
  color. A background or text color you picked yourself is left exactly as it is.
- **Creating & editing** — built-in themes are read-only. **Duplicate** turns one into an editable
  user theme, then **Edit** exposes a color well per token, grouped under Chrome / Text / Accent &
  Status / Syntax / Diff, above a live preview; changes apply as you pick. The preview is drawn as a
  miniature Suit window — tab strip, code block, diff rows, terminal, status dots — with the full
  token set as a strip beneath it, so you see the effect rather than the swatch. `focusBorder`,
  `selection`, the diff hunk-header color, and the commit-graph lanes aren't editable: they derive
  from the accent, type, and status tokens automatically, so a theme can't contradict itself.
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
    "colors": {
      "bg": "#2E3440", "accent": "#88C0D0", "textPrimary": "#ECEFF4",
      "syntaxKeyword": "#81A1C1", "syntaxString": "#A3BE8C",
      "diffAdded": "#A3BE8C", "diffAddedBg": "#A3BE8C2E"   // 8 digits = with alpha
    }
  }
  ```

  Colors are `"#RRGGBB"` hex strings (a leading `#` is optional and case doesn't matter), or
  `"#RRGGBBAA"` where a token is translucent — the two diff row washes are, so they composite over
  whatever a pane's background happens to be instead of punching an opaque band through it. Every
  color is optional: any token a file omits — or spells wrong — falls back to the built-in default,
  and unknown keys are ignored, so partial themes and themes authored against an older or newer Suit
  still load cleanly. A theme file written before the syntax and diff tokens existed keeps working:
  those tokens simply fall back to Suit Dark's.

## Safety

- **Paste safety** — pasting multi-line text or `curl`/`wget`-into-a-shell one-liners prompts
  with a preview of exactly what's about to be sent.
- **Clipboard hygiene** — OSC 52 "copy to clipboard" from remote/tmux sessions works, but
  OSC 52 *read* queries are denied outright, so nothing in a pane can silently read your
  clipboard.
- **Login shells** — shells start login+interactive (`-l -i`), so `~/.zprofile` PATH setup
  (Homebrew) and `~/.zshrc` (Powerlevel10k, oh-my-zsh) load the same as in Terminal.app.
