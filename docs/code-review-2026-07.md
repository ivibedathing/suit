# Code review — Suit `main` (2026-07)

A full-codebase bug hunt across all seven subsystems (~37k LOC, 173 Swift files),
run as parallel per-subsystem reviews and then cross-verified. The focus was
**major bugs** — crashes, data loss, concurrency races, resource leaks, and
logic errors — with a secondary lens on whether the code stays **AI-friendly,
maintainable, and easy to navigate**.

**Headline:** the codebase is in good shape. The load-bearing machinery that is
easiest to get wrong — derived focus / KVO teardown, the `~/.suit` atomic-write
stores, ripgrep/git argument passing (no shell), SSH password handling
(Keychain-only), the autopilot state machine and its pure budget/scheduler/roadmap
cores — was specifically audited and found **correct**. No CRITICAL crash or
wrong-merge/gate-skip bug was found. The real risks cluster in two themes:
**(A) silent data loss on write/decode paths**, and **(B) synchronous work on the
main thread**.

Five fixes are applied in this branch (see [§ Fixed here](#fixed-in-this-branch)):
the two parser/infra bugs plus all three data-loss bugs (autosave clobber, UTF-8
corruption, and the systemic store/state decode-wipe). The remaining findings —
mostly main-thread blocking and lower-severity correctness — are documented as
prioritized follow-ups (see [§ Recommended follow-ups](#recommended-follow-ups)).

---

## Severity summary

| # | Severity | Area | Bug | Status |
|---|----------|------|-----|--------|
| 1 | HIGH | Git/review | DiffParser mis-tags `--`/`++` **content** as a file header → line numbers desync | ✅ fixed |
| 2 | HIGH | Infra (git) | `runProcess` never drains stderr → >64 KB stderr **deadlocks** any git call | ✅ fixed |
| 3 | HIGH | Viewer | Autosave overwrites a file **changed on disk** (no mtime re-check) → Claude's edit lost | ✅ fixed |
| 4 | HIGH | Viewer | Lossy UTF-8 decode marks non-UTF-8 files editable → **whole-file corruption** on save | ✅ fixed |
| 5 | MEDIUM | Persistence | Decode failure **wipes the store** on next write (all `~/.suit` stores + state restoration) | ✅ fixed |
| 6 | MEDIUM | Claude | statusline/hook **RMW race** on `sessions/<sid>.json` reverts `done → working` | 📋 follow-up |
| 7 | MEDIUM | Claude | Plan transcript read + JSON-parsed in full **on the main thread** | 📋 follow-up |
| 8 | MEDIUM | Multiple | Synchronous git on the main thread (worktree finish, "What Changed", session monitor) | 📋 follow-up |
| 9 | MEDIUM | Git/blame | `GitBlame.parse` only accepts 40-char SHAs → **broken on SHA-256 repos** | 📋 follow-up |
| 10 | MEDIUM | Persistence | `DispatchSource` handler captures its own `source` → **fd/source leak** if teardown skipped | 📋 follow-up |
| 11 | MEDIUM | Autopilot | Run cost is **max single session, not sum** → undercounts on any respawn/adoption | 📋 follow-up |
| 12 | MEDIUM | Autopilot | Unbounded git/gh calls (no timeout) → a hung `git fetch` **wedges the engine** silently | 📋 follow-up |
| 13 | MEDIUM | Settings | Terminal/background colors saved deviceRGB, reloaded calibratedRGB → **color drifts** each relaunch | 📋 follow-up |
| 14 | LOW–MED | Claude | Bracketed-paste payload not sanitized → embedded `ESC[201~` **escapes the paste** | 📋 follow-up |
| 15 | LOW | Claude | `PlanParsing` bullet strip drops one leading space, not all | 📋 follow-up |
| 16 | LOW | Autopilot | No cross-instance lock on `autopilot/state.json` (multi-instance / synced `$HOME`) | 📋 follow-up |
| 17 | LOW | Autopilot | `BudgetMonitor` re-fires interrupt when a session blips out of one sample batch | 📋 follow-up |

---

## Fixed in this branch

### 1 — DiffParser mis-tags `--`/`++` content as a file header
`swift/Sources/suit/DiffParser.swift`

The meta-prefix check (`hasPrefix("---")` / `hasPrefix("+++")`) ran **before** the
`+`/`-` content classification. Inside a hunk, a deleted line whose content begins
with `--` produces the raw line `---…` and an added line beginning with `++`
produces `+++…` — both were tagged `.meta` and, crucially, the meta branch
`return`s **without advancing** `oldLine`/`newLine`. Every subsequent line in that
hunk was then numbered off-by-one (or more).

**Failure scenario:** a hunk that deletes a YAML/Markdown `---` separator, a docs
`--flag` line, or C `--i` desyncs the line counter. A review comment anchored on
those lines (`GitView` posts `gh pr review` against `Line N`) lands on the **wrong
line**, and unified/side-by-side anchoring drifts — silently.

**Fix:** track an `inHunk` state. File-header/metadata prefixes are only honored
outside a hunk body (where they actually occur); inside a hunk every line is
content and is classified as addition/deletion/context. `\ No newline at end of
file` is matched independently since a real content line never starts with a bare
backslash. Five regression assertions added to `scripts/diffparser-test/main.swift`
(verified failing on the pre-fix parser, passing after).

### 2 — `runProcess` never drains stderr → deadlock on chatty git
`swift/Sources/suit/FileIndex.swift`

`runProcess` (the shared helper behind `GitStatus`, `GitBlame`, `WorktreeTasks`,
`CommitGraphPane`, `FeedbackInbox`, `GitBranchList`, the diff pane…) set
`standardError = Pipe()` but **never read it**, then read stdout to EOF. Once a git
command writes past the ~64 KB stderr pipe buffer, the child blocks on the stderr
write, never closes stdout, and `readDataToEndOfFile()` on stdout hangs **forever**
— a permanent stall of that background worker (blame gutter / history / status
badges never update).

**Fix:** route stderr to `FileHandle.nullDevice` (it was discarded anyway — the
function only ever returns stdout), so a flood of git warnings/advice can't wedge
the reader.

> Note for follow-up: `WorktreeTasks.runGit` and `GitHubCLI.run` read stdout fully
> *before* stderr, so a >64 KB stderr with unread stdout can wedge them the same
> way. Draining both concurrently (or nulling the unused one) is the durable fix.

### 3 — Autosave clobbers an externally-modified file
`swift/Sources/suit/FileViewerPane+Editing.swift`

`performSave` wrote unconditionally; reconciliation only ran on `appBecameActive`.
If Suit stayed frontmost while Claude (or `$EDITOR`) rewrote the open file, the 1 s
autosave overwrote that content with the stale buffer — silent loss on the app's
*central* workflow. **Fix:** before writing, re-stat the file; if its mtime moved
since load/last-save, run the existing pure `resolveExternalChange` decision on the
disk-vs-buffer content — `ignore` proceeds, `reload` adopts the disk version, and a
divergent dirty buffer (`warn`) routes to the conflict sheet instead of overwriting.

### 4 — Lossy UTF-8 decode → whole-file corruption
`swift/Sources/suit/FileViewerPane.swift`

Load used `String(decoding: data, as: UTF8.self)` (which never fails — invalid bytes
become U+FFFD) and unconditionally set `editable = true`; the NUL-byte binary guard
misses single-byte encodings. A Latin-1/Windows-1252 file opened editable with every
non-ASCII byte already a replacement char, and the first autosave rewrote the whole
file. **Fix:** decode with `String(bytes:encoding:.utf8)` — nil for invalid UTF-8 —
and only mark the file editable when it's valid; otherwise show a best-effort lossy
view **read-only** so a save can never corrupt it.

### 5 — Decode failure wipes the store (systemic)
`swift/Sources/suit/StoreFile.swift` (new) + `Notes` / `Bookmarks` / `Favorites` /
`SSHHosts` / `Markers` / `StateRestoration.swift`

Every `~/.suit` store loaded with `try?` and, on any failure, started from an empty
model — the next mutation then atomically overwrote the good-but-unreadable file, so
one malformed `notes.json` erased every note. `StateRestoration` was all-or-nothing
per launch: one bad field wiped every window/tab/layout, and `save()` dropped the
legacy fallback on the first V2 *write*. **Fix:** a shared `StoreFile.load` helper
distinguishes "absent" (start empty — safe) from "present but unreadable" (quarantine
to `<name>.corrupt-<epoch>` before returning nil, so the bytes survive); all five
stores route through it. `StateRestoration` now decodes windows one at a time (a
corrupt window is dropped, not the whole session) and clears the legacy key only
after a V2 blob decodes. Covered by a new standalone harness
(`scripts/storefile-test.sh`, wired into `scripts/test.sh`).

---

## Recommended follow-ups

The data-loss items are fixed above; these remain, ordered by impact.

### Theme B — main-thread blocking

**7 · Plan transcript parsed on the main thread** — `PlanApprovalPane.load` →
`PlanParser.latestPlan` reads the whole JSONL transcript and `JSONSerialization`s
every line on the main thread. A tens-of-MB session beachballs on open/refresh.
Move off-main; scan from the end for the last `ExitPlanMode`.

**8 · Synchronous git on the main thread** — `WorktreeTasks.finish`/`currentBranch`
in `Pane.finishClaudeTask`, `isTaskWorktree` in `PaneTerminalView.menu(for:)` (every
right-click), `MarkerCatchUp.compose` in "What Changed Since Mark" (spawns one
`git diff --no-index` **per untracked file**, and is called twice back-to-back), and
`ClaudeSessions.reload` (directory scan + JSON parse of every session file on
`.main`). Each blocks the whole app. Dispatch to a utility queue, hop back to main
for UI.

**13 · Color-space round-trip mismatch** — `AppDelegate+Appearance.swift` saves
components via `usingColorSpace(.deviceRGB)` but reloads with
`NSColor(calibratedRed:…)`. The stored triple is re-interpreted in a different color
space, so terminal text / default background colors drift slightly on every
relaunch. **Fix:** use the same space on both sides (`NSColor(srgbRed:…)` /
`deviceRGB`).

### Theme C — concurrency & correctness

**6 · statusline/hook RMW race** — `scripts/claude/suit-statusline.sh` and
`suit-session-state.sh` both do a non-atomic read-modify-write of
`sessions/<sid>.json`. The `mv` makes each write atomic (readers never see a half
file — good) but not the RMW: a late statusline write whose `jq` preserved a stale
`state` can revert a hook's `done → working`, sticking the session "busy" forever
and suppressing the done-transition (Dock badge, Activity feed). **Fix:** `flock`
per session, or have the statusline never write `state`.

**9 · `GitBlame.parse` breaks on SHA-256 repos** — the porcelain header is
recognized only at `first.count == 40`; a 64-char SHA-256 sha never matches, so
every line gets an empty sha (reported as uncommitted). **Fix:** accept 40 **or**
64 hex chars.

**10 · `DispatchSource` self-capture leak** — `CheckpointTimeline` and
`BackgroundTaskPane` event handlers read `source.data` without a capture list,
strongly capturing the source; setting `watchSource = nil` doesn't break the cycle
(only `cancel()` does). If teardown is skipped, the fd + source leak for the app's
life. **Fix:** `[weak source]` or read via `self.watchSource?.data`.

**11 · Autopilot run cost is max, not sum** — `AutopilotEngine+Session.sampleSessionMetrics`
keeps `max(cost)` over the pinned session; a respawn starts a new session at $0, so
a run that spent $4.20 + $3.10 across two sessions reports **$4.20**. Reporting only
(budget guards read session files directly), but every death/respawn/adoption
undercounts. **Fix:** sum per-session maxima.

**12 · Unbounded git/gh in the engine** — preflight/verify/merge/cleanup call
`WorktreeTasks.runGit`/`GitHubCLI` with no timeout inside a `beginBackgroundJob`
hold. A `git fetch` that blocks (credential prompt, black-hole network) never
releases `inFlight`, so every later `tick()` short-circuits and autopilot silently
stops with no signal. **Fix:** hard timeout (SIGTERM/SIGKILL) returning `.failure`;
set `GIT_TERMINAL_PROMPT=0`.

**14 · Bracketed-paste not sanitized** — `SessionControl.send` wraps text in
`ESC[200~…ESC[201~` without stripping an embedded `ESC[201~`/bare `\r`; a payload
copied from a transcript can terminate the paste early and inject the remainder as
live TUI input. **Fix:** strip/neutralize the paste markers before wrapping.

**15 · `PlanParsing` bullet strip off-by-one** — a bullet with two spaces after the
marker keeps one leading space (numbered-list branch already drops all). **Fix:**
`drop(while: { $0 == " " })`.

**16 / 17 · Autopilot multi-instance lock / budget re-fire** — no `flock` on
`autopilot/state.json` (two instances or a synced `$HOME` could double-drive a
phase); `BudgetMonitor.evaluate` drops a still-over-cap mark when a session is
merely absent from one sample batch, re-tripping the interrupt on reappearance.
Low likelihood; noted for completeness.

---

## Maintainability & navigation (the AI-friendliness lens)

The codebase is already well-organized for an agent — the `CLAUDE.md` file map, the
Foundation-only pure-core pattern with standalone harnesses, and small single-purpose
files make it easy to locate and safely modify logic. A few sharp edges:

- **Stale reference in the file map.** `CLAUDE.md` lists `RootHeaderView.swift`, but
  the file is `ProjectHeaderView.swift`. An agent told to touch "the root header"
  will grep and find nothing. *(Worth a one-line correction in `CLAUDE.md`.)*
- **Distributed tab-ownership invariants.** `Tab.store` / `Tab.pane` /
  `Tab.homePane` plus `PaneContent.pane`/`.tab` must be kept mutually consistent,
  but the invariants are enforced entirely in `TerminalWindowController`, far from
  the `Pane`/`TabStore` code that mutates them (`Pane.display` silently reassigns
  `homePane`; `TabStore.remove` deliberately leaves back-refs dangling). Local edits
  to `Pane`/`TabStore` are easy to get subtly wrong. A short invariant comment at
  each mutation site would help.
- **Split lifecycle across files.** The screensaver stop/remove correctness step
  lives in a `Pane+Screensaver` extension separate from `Pane.teardown` and
  `PaneScreensaverView`; the same "the fix is in a different file than the risk"
  shape recurs for the git-subprocess helpers. Not bugs, but they raise the cost of
  a confident local change.

---

## Verified clean (audited, no fix needed)

So future reviews don't re-tread these: derived-focus KVO auto-invalidates
(block-based observation) and theme/notification observers are paired with removal;
palette commands rebuild fresh each open (no stale registrations); settings keys
round-trip completely (no missing-persist path); ripgrep and all git/gh calls pass
argv directly (no shell → no command injection); store writes are `.atomic`; SSH
passwords are Keychain-only and the auto-auth matcher is genuinely one-shot; the
viewer's NSRange/UTF-16 offset math is consistently NSString-based (no
String.Index/Int mixing) and async staleness is guarded by `loadGeneration`; the
autopilot pure cores (`RoadmapParser`, `AutopilotScheduler` pace/night-window math,
`BudgetGuardrails`) and the merge state machine (no double-merge, conservative
leftover cleanup) are correct.

---

*Method: seven parallel subsystem reviews (tabs/panes, git/GitHub, autopilot/fleet,
Claude integration, viewer/editing, sidebar/search/stores, app-shell/settings), each
reading the actual source; findings cross-checked and the two fixed items verified
against the test harness and a clean build.*
