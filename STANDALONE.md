# Autopilot — autonomous ROADMAP.md worker built into Suit (Phase 32)

**Standalone design + implementation plan.** This document is self-contained: a fresh Claude
Code session can implement the feature from it without any other context. Per CLAUDE.md
workflow, implementation happens in its own worktree on branch `task/phase32-autopilot`, ships
as a PR, and updates README.md / ROADMAP.md / CLAUDE.md in the same PR.

---

## 1. Context

Suit already hosts Claude Code sessions in terminal tabs, tracks their state via hook scripts
(`~/.suit/sessions/<id>.json`: working / needs-input / done), and mirrors global rate-limit
usage into `~/.suit/claude-status.json` (the statusline script copies the **entire** statusline
JSON, so `rate_limits.five_hour/seven_day.used_percentage` **and** `resets_at` are already on
disk). The goal: make the app **use every bit of the Claude Code token limits autonomously** —
a scheduler inside Suit that, whenever budget allows, spins up a Claude session that implements
the next unshipped `ROADMAP.md` phase end-to-end (worktree → implementation → build → README →
✅ mark → commit → push → PR), then the app gates and auto-merges the PR and loops. The user
steers **only by editing ROADMAP.md**.

### Settled decisions (user-confirmed)

| Decision | Choice |
|---|---|
| Where it lives | **Built into Suit (Swift)** — the app is the orchestrator; runs are visible tabs |
| Merge policy | **Auto-merge after gates**: app-run `build.sh` green + headless Claude review approves; gate failure leaves the PR open + flags the user |
| Budget | **All modes user-switchable**: Pace-to-reset / Max-out / Night-shift, with configurable ceilings and hours |
| Concurrency | **One run at a time** |
| Permissions | Workers run `--dangerously-skip-permissions` inside their worktree |

### Load-bearing facts (verified in code, 2026-07-06)

- **Spawn plumbing exists.** `WorktreeTasks.createTask(projectRoot:name:)` (WorktreeTasks.swift:30)
  creates `.claude/worktrees/<slug>` on branch `task/<slug>` from HEAD and returns the absolute
  path. The tab recipe is `TerminalWindowController.startClaudeTask(named:)`
  (TerminalWindowController.swift:1550): `TerminalPaneContent()` → `Tab(content:)` →
  `tab.customTitle = …` → `store.insert(tab)` → `content.start(in: dir)` → **0.4 s delay**
  (zsh rc files — load-bearing) → `terminalView.send(txt: "claude\n")` (commands are *typed
  into the pty*, never exec'd). All tab/pty/store operations are **main-queue only**.
- **Usage freshness.** `claude-status.json` is written only while an *interactive* claude
  renders its statusline; headless `claude -p` never refreshes it. Swift's
  `ClaudeUsage`/`readUsage` (ClaudeSessions.swift:71-79, 189-211) parses percentages but **not
  `resets_at`**, and returns `nil` when the snapshot is >30 min old. ⇒ the worker must be
  **interactive claude in a visible tab** (usage stays fresh, session awareness works, the user
  can watch/intervene); only the review gate is headless. The scheduler needs a new ungated
  reader plus `resets_at` parsing.
- **Stop-hook trap.** `suit-session-state.sh` maps Stop → `done` at **every** turn end, so
  session `done` means "claude stopped talking", not "phase shipped". Completion must be
  verified against world state (see §2.6).
- **gh.** `GitHubCLI` (GitBranches.swift:114-262) resolves gh from
  `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, `/run/current-system/sw/bin`, then
  login-shell `command -v gh`; has `pullRequests(root:)` (`pr list --json
  number,headRefName,state,url,statusCheckRollup`), `createPR`, `summarizeChecks`,
  `defaultBranch` (private → make internal) — **no merge operation exists** (new code).
  **gh is currently NOT installed on this machine**, so a "blocked: install gh" first-run state
  is expected and must be handled gracefully.
- **`WorktreeTasks.finish(merge:true)` is unsuitable** for the PR flow: it performs a *local*
  `--no-ff` merge into whatever branch the main checkout currently has out, then deletes the
  branch. Post-remote-merge cleanup is new code.
- **Scheduler host.** AppDelegate owns a 3 s `sessionRefreshTimer` with a tick counter
  (AppDelegate.swift:117-137; every 10th tick reloads `ClaudeSessionMonitor`). The engine tick
  hangs off this timer.
- **Conventions.** Subsystem state = `~/.suit/*.json` store singletons following FavoritesStore
  (Favorites.swift:9-82): `static shared`, `didUpdate` Notification, Codable model with
  all-optional fields, fileURL resolved from the `$HOME` env var (test sandboxing), atomic
  writes. Settings = AppDelegate public vars + central `loadSettings()`/`saveSettings()` with
  bare camelCase UserDefaults keys + a SettingsWindowController `NSStackView` section whose
  controls write through `appDelegate.xChanged(...)` and are re-read in `show()`. Threading =
  GCD (no async/await): blocking git/gh/Process work on `DispatchQueue.global(qos:)`, results
  back on main, `loadToken`-style staleness guards (GitView.swift:548). Notifications =
  `ClaudeAttentionCenter` (ClaudeAttention.swift) with the `Bundle.main.bundleIdentifier != nil`
  guard (bare swiftc dev runs have no bundle identity). `SessionControl.send(text:to:submit:)`
  (PromptComposer.swift:14) bracketed-paste-wraps multi-line text into a session's pty with a
  CR 0.15 s later. `build.sh` is worktree-portable (paths relative to the script), exits
  nonzero on failure, ~1–2 min. Env-override precedent for bundled binaries: `SUIT_RG_PATH`,
  `SUIT_SCRIPTS_PATH`.
- **Roadmap drift is real.** Phases 14, 17, 18, 19, 25 are merged on GitHub but their ROADMAP.md
  headings lack `✅ shipped`. See §2.12 — this makes the first runs a safe shakedown.
- **Repo merge style**: history is "Merge pull request #N" merge commits ⇒ `gh pr merge --merge`
  (not squash).

---

## 2. Design

### 2.1 Components (new files in `swift/Sources/suit/`; build.sh's `*.swift` glob picks them up)

| File | Types | Role |
|---|---|---|
| `AutopilotEngine.swift` | `AutopilotEngine` (singleton, main-queue), `AutopilotEngineState`, `AutopilotBlockReason` | State machine, tick driver, spawn/adopt/nudge, gate+merge orchestration; monotonic `generation` token drops stale background callbacks |
| `AutopilotScheduler.swift` | `AutopilotScheduler` (pure static funcs), `AutopilotBudgetMode`, `UsageSnapshot` | UI-free budget math `mayStartRun(mode:snapshot:now:config:)` — compiles standalone for tests |
| `AutopilotStore.swift` | `AutopilotStore`, `AutopilotRun: Codable`, `CompletedRun: Codable` | `~/.suit/autopilot/` persistence: `state.json` (current run, atomic rewrite per transition), `history.jsonl` (append-only), `autopilot.log` (human-readable lines), `logs/<slug>/build-N.log` + `review-N.log` |
| `RoadmapParser.swift` | `RoadmapPhase`, `RoadmapParser` (pure static) | Parses `^### Phase (\d+) — (.+)$` headings; shipped = `✅` anywhere in heading (covers the `(…)` parenthetical variants), skipped = `⏸` anywhere in heading; eligible = first phase that is neither, in document order; spec body = lines until the next `###`/`##` |
| `AutopilotGates.swift` | `AutopilotBuildGate`, `AutopilotReviewGate`, `ReviewVerdict` | Background-queue `Process` wrappers: build.sh runner (log capture, 15-min timeout via DispatchSourceTimer → terminate); headless `claude -p --output-format text` runner (prompt on **stdin** — no arg quoting/length hazards; binary resolved `SUIT_CLAUDE_PATH` env → `/opt/homebrew/bin/claude`, `~/.local/bin/claude`, `~/.claude/local/claude` → login-shell `command -v claude`, mirroring GitHubCLI); pure `parseVerdict` |
| `AutopilotPrompts.swift` | `AutopilotPrompts` (static) | Worker / resume / nudge / build-failure / review-rejection / conflict prompt composition; worker template overridable via `~/.suit/autopilot-prompt.md` when present |

**Touched existing files**

- `GitBranches.swift` — `GitHubCLI` gains: `SUIT_GH_PATH` env override prepended to path
  candidates (test hook); `mergePR(root:number:) -> Result<String, WorktreeTaskError>` →
  `gh pr merge <n> --merge` (**no** `--delete-branch`: the branch is checked out in a worktree
  and gh's local delete would fail); `prState(root:number:)` → `gh pr view <n> --json
  state,mergedAt,body` (merge confirmation, adoption, trailer reads); `isAuthenticated(root:)`
  → `gh auth status`; `defaultBranch(root:)` made internal.
- `ClaudeSessions.swift` — `ClaudeUsage` gains `fiveHourResetsAt: Date?` /
  `sevenDayResetsAt: Date?` (parse `rate_limits.*.resets_at` defensively: epoch number or
  ISO8601 string); new `readUsageSnapshot()` returning raw values + `capturedAt` **without**
  the 30-min staleness gate (the UI keeps the gated `usage`; the scheduler applies its own
  staleness policy).
- `WorktreeTasks.swift` — new `removeAfterRemoteMerge(worktreePath:) -> String?`: resolve
  `mainRoot(ofWorktree:)`, `git worktree remove --force <path>` (the build gate leaves an
  untracked `build/` dir, so plain remove refuses; force is safe post-merge), `git branch -D
  task/<slug>`, best-effort `git push origin --delete task/<slug>`. `finish(merge:)` stays
  untouched and unused by Autopilot.
- `AppDelegate.swift` — settings vars + `loadSettings()`/`saveSettings()` keys (§2.9); engine
  init + `adoptOnLaunch()` in `applicationDidFinishLaunching` (after the session monitor
  exists); `AutopilotEngine.shared.tick()` added inside the existing 3 s timer closure
  (:125-133); palette commands in `paletteCommands()` (:887); `autopilotXChanged(...)`
  write-through setters; `focusAutopilotRunTab()`.
- `TerminalWindowController.swift` — `openAutopilotRunTab(directory:title:) -> Tab` cloned from
  `startClaudeTask` (:1550) minus worktree creation (the engine already made it); types
  `claude --dangerously-skip-permissions <extraArgs>\n` after the 0.4 s delay; inserts
  **without stealing focus** (no `activate` unless the window is empty — "attention is
  signaled, never forced"). Two-line intercept at the top of `tabProcessDidExit` (:593): if the
  engine owns this tab id, notify `AutopilotEngine.shared.workerTabExited(tab)` and skip the
  clean-exit auto-close so the scrollback survives for debugging.
- `ClaudeAttention.swift` — `postAutopilotEvent(title:body:identifier:)` on
  `ClaudeAttentionCenter` (it is already the UNUserNotificationCenter delegate — a second
  delegate class would fight it; route clicks by identifier prefix `autopilot-`).
- `SidebarView.swift` — `AutopilotRowView` inside `ClaudeUsageFooterView` (:334), see §2.10.
- `SettingsWindowController.swift` — "Autopilot" section, see §2.9.
- `PromptComposer.swift` — `SessionControl.send` gains optional `submitDelay` (default 0.15 s;
  Autopilot passes 0.5 s so a multi-KB paste is fully consumed before the CR).
- `README.md`, `ROADMAP.md` (new Phase 32 entry), `CLAUDE.md` (file-map bullets) — §3.

### 2.2 Run state machine

Engine states: `off`, `idle`, `running(run)`, `paused`, `blocked(reason)`, `doneAllPhases`
(auto-recovers when ROADMAP.md's mtime changes — the steering loop).

Run stages (persisted to `state.json` on every transition; `preflight`/`spawning` are transient
and never persisted):

```
working → gating(build) → gating(review) → merging → cleanup → (cleared → idle)
   ↑           |                 |             |
   └─feedback──┴────feedback─────┘      conflict feedback → working
```

| From | Trigger | Condition | To |
|---|---|---|---|
| idle | engine tick | `mayStartRun` == go AND preflight passes | createTask → spawn tab → **working** |
| idle | engine tick | preflight fails | **blocked(reason)** or **doneAllPhases** |
| working | `ClaudeSessionMonitor.didUpdate` | pinned session flips to `done` | completion verification (§2.6) → all green → **gating(build)**; else nudge, stay **working** |
| working | didUpdate | session flips to `needsInput` | stall handling (§2.8) |
| working | `workerTabExited` | any exit while working | died handling: one respawn `--continue`, else **blocked** |
| gating(build) | Process done (bg → main, generation-checked) | exit 0 | **gating(review)** |
| gating(build) | " | nonzero, attempts < max | log-tail feedback into live session → **working** |
| gating(review) | claude -p done | `VERDICT: APPROVE` | **merging** |
| gating(review) | " | `VERDICT: REJECT`, attempts < max | findings into live session → **working** |
| gating(review) | " | unparseable / binary missing / 2× timeout | **blocked(.reviewGateBroken)** (global) |
| merging | `gh pr merge` result | success, confirmed `prState == MERGED` | post-merge sync → **cleanup** |
| merging | " | "not mergeable" (main moved) | conflict feedback → **working** (cap 2) |
| cleanup | git ops done | — | history + notification + close tab → **idle** |
| any | palette Pause | — | **paused** (run record kept) |

**Relaunch adoption** (`adoptOnLaunch()`, called once at startup; app quit kills pty children,
so a live worker never survives relaunch — its session JSON may read "working" with a dead pid):

```
run := store.run; nil → idle/off
!GitHubCLI.isAvailable → blocked(.ghMissing), run kept
pr := pullRequests(root)[run.branch]:
  MERGED                     → stage = cleanup
  OPEN                       → stage = gating(build)   (gates are idempotent; re-run both)
  no PR && worktree exists   → stage = working: respawn tab with
                               `claude --dangerously-skip-permissions --continue` + resume prompt
  no PR && no worktree       → clear run → idle        (nothing real happened)
  was merging && OPEN        → retry merge (idempotent)
```

`adoptionStage(worktreeExists:prState:) -> Stage` is a pure function — truth-table tested.

### 2.3 Preflight (ordered; first failure = distinct `AutopilotBlockReason`)

1. `autopilotProjectRoot` set + is a git repo (`FileIndex.gitRoot`) → `.noProject`
2. ROADMAP.md exists + `RoadmapParser` finds an eligible phase → else `doneAllPhases`
3. `GitHubCLI.isAvailable` → `.ghMissing` ("Install the gh CLI — brew install gh"; **expected
   first-run state on this machine**)
4. `gh auth status` → `.ghUnauthenticated`
5. Main checkout on the default branch (`currentBranch == defaultBranch`) → `.mainNotOnDefault`
   (correctness gate: `createTask` branches from the main checkout's HEAD)
6. Main checkout clean → `.mainDirty`
7. `git fetch origin` → `.offline`; `git merge --ff-only @{u}` → `.mainDiverged`
8. No leftover `.claude/worktrees/<slug>` or `task/<slug>` branch; auto-clean **only** when the
   branch is fully merged into origin's default and the worktree is clean, else
   `.leftoverWorktree` (a human decides — it may hold unshipped work).

Enable-time check in Settings: `ClaudeIntegration.status() == .installed` (the hook/statusline
files are Autopilot's nervous system) — refuse to enable with a specific alert otherwise, and
also verify `GitHubCLI.isAvailable` with an install hint.

### 2.4 Scheduler math (pure, in `AutopilotScheduler`)

```
effectivePct(pct, resetsAt, now):
    pct == nil        → 0     // never measured: optimistic; the worker refreshes within ~1 min
    now ≥ resetsAt    → 0     // window rolled over since capture
    else              → pct

week = max(effective(sevenDayPct), effective(modelWeeklyMaxPct))  // model-scoped weekly can bind first
five = effective(fiveHourPct)

hard gates (all modes):
    week ≥ weeklyHardStop (98)   → wait(until: sevenDayResetsAt)
    five ≥ fiveHourCeiling (85)  → wait(until: fiveHourResetsAt)

maxOut:     go while week < weeklyCeiling (95), else wait(sevenDayResetsAt)
paceTo100:  weekStart = sevenDayResetsAt − 7d
            allowed   = clamp(elapsed/(7d), 0, 1) × paceTargetPct (100)
            go while week < allowed         // no resets_at → maxOut fallback, logged
nightShift: hour ∈ [nightStart, nightEnd) with midnight wrap (default 22→7), + weeklyCeiling
```

Returns `.go` or `.wait(until: Date?, why: String)` (the `why`/`until` feed the footer row).
Budget gates **starting** only — an in-flight run always finishes (nudges/gates are cheap
relative to the run). Tick throttles internally: budget from cached monitor state every tick;
ROADMAP mtime check ~10 s; git/gh polls ≥30 s and stage-scoped; a single `inFlight` flag
prevents overlapping background work. The last snapshot (with parsed `resets_at`) is mirrored
into `state.json` so a relaunch can still show "next run ~03:40".

### 2.5 Worker launch + prompt delivery

**Two-stage delivery** (avoids every shell-quoting hazard — the launch path types raw text
into zsh with zero escaping):

1. **Launch**: tab starts a shell in the worktree; after the 0.4 s rc delay it types the one
   short line `claude --dangerously-skip-permissions <autopilotExtraArgs>` (args validated
   newline-free).
2. **Inject on session-ready**: the engine watches `ClaudeSessionMonitor.didUpdate` for a
   session whose `cwd == worktreePath` (unique per run; pid ancestry via
   `ClaudeSessionAssigner` confirms). The statusline writes the session file as soon as the
   TUI renders, so file-appears ≡ ready-for-input. Then
   `SessionControl.send(text: workerPrompt, to: terminal, submit: true, submitDelay: 0.5)`.
   The session id is **pinned** in `state.json` as the run's worker; all later reads and
   feedback sends target it. No matching session within 20 s → `blocked("claude session never
   became ready — check the run tab")`, tab left open (covers the one-time
   `--dangerously-skip-permissions` acceptance dialog).

### 2.6 Worker prompt template (full draft; composed by `AutopilotPrompts.workerPrompt`)

Spec text is embedded **verbatim** (snapshotted at spawn into `state.json`) — immune to
concurrent ROADMAP edits, and the review gate judges against the identical artifact.

```
You are an Autopilot worker session run by the Suit app, working unattended.
You are in a dedicated git worktree at <WORKTREE_PATH> on branch task/<SLUG>.
Everything you do happens ONLY inside this worktree.

YOUR JOB
Implement ROADMAP.md "Phase <N> — <TITLE>" end-to-end, exactly per the spec
below (snapshotted when this run started — treat it as the contract even if
ROADMAP.md changes underneath you).

--- PHASE SPEC (verbatim from ROADMAP.md) ---
<heading line + full body text of the phase>
--- END PHASE SPEC ---

First read CLAUDE.md and follow every convention in it (plain swiftc via
./build.sh, no SwiftPM/Xcode, vendor any dependency as source, document
shipped features in README.md).

REQUIRED OUTPUTS — all of them, in order:
1. The implementation, including the spec's Verification item.
2. ./build.sh exits 0 (run it from the worktree root; confirm the exit code).
3. README.md updated to document the new user-facing behavior (features,
   shortcuts, settings) in the matching Features section.
4. ROADMAP.md: append " — ✅ shipped" to THIS phase's heading only (add a short
   parenthetical if something deliberately deviated). Touch no other phase.
5. Commit everything on this branch. Subject of the final commit:
   "Phase <N>: <short summary>". The tree must be clean afterwards.
6. git push -u origin task/<SLUG>
7. gh pr create --title "Phase <N>: <TITLE>" --body "<body>" where the body
   starts with what shipped and how you verified it, and ENDS with exactly
   these two lines:
   Autopilot-Phase: <N>
   Autopilot-Slug: <SLUG>

IF THE PHASE IS ALREADY IMPLEMENTED (roadmap drift)
Verify it genuinely works (run its Verification item and ./build.sh). Then do
outputs 3–7 anyway as a docs-only change: mark the heading "— ✅ shipped
(docs-only: implementation predated this run)", fill any README gap, commit,
push, open the PR with the same trailer lines. Never re-implement working code.

HARD RULES
- Never merge a PR; never run "gh pr merge"; never push to main/master.
- Never modify files outside <WORKTREE_PATH>; never cd out of it to run
  write-operations; never touch the main checkout or other worktrees.
- Never edit any other phase's text in ROADMAP.md; never reorder phases.
- Never force-push or rewrite already-pushed history.
- If genuinely blocked (contradictory spec, missing external dependency),
  commit what exists, push, and open the PR with the body's final line
  "Autopilot-Blocked: <one-line reason>" INSTEAD of the Autopilot-Phase line,
  then stop.

WHEN THE PR EXISTS
Print exactly this line and stop:
AUTOPILOT DONE PHASE <N>
Suit itself builds, reviews, and merges — that is not your job.
```

### 2.7 Completion detection (the Stop-hook trap, addressed)

Session `done` only **triggers verification** (background, throttled ≥30 s), never trust:

1. branch has commits ahead of default (`git rev-list --count`)
2. branch pushed (`git rev-parse origin/task/<slug>`)
3. PR open for the branch (`GitHubCLI.pullRequests`), body trailer `Autopilot-Phase: <N>`
   present (`Autopilot-Blocked:` → phase blocked with that reason)
4. worktree clean (`hasUncommittedChanges == false`)
5. the worktree's ROADMAP.md marks the phase ✅

All green → gates. Any miss → nudge the live session with the **specific** missing items
(each nudge flips the session back to working via the UserPromptSubmit hook, so the cycle
re-arms); ≥2 min between nudges, max 5 → blocked. Watchdogs: dead pid + frozen `updated_at`
>30 min → one respawn with `--continue` + resume prompt, second death → blocked; per-attempt
wall-clock cap 90 min → blocked (tab left open). The printed `AUTOPILOT DONE PHASE <N>` line
is for humans reading the tab — never parsed.

### 2.8 Gate + merge pipeline

1. **Build gate** (free, first): `Process` runs `<worktree>/build.sh`, cwd = worktree, stdout+
   stderr streamed via Pipe readabilityHandlers to `logs/<slug>/build-<attempt>.log`, 15-min
   timeout. Fail → last ~100 lines fed into the live session (bracketed paste keeps the log one
   input unit) → `working`; `buildAttempts` max 3 → phase blocked.
2. **Review gate**: headless `claude -p --output-format text` via Process, prompt on **stdin**,
   cwd = worktree, 10-min timeout, output to `review-<attempt>.log`. (A headless run doesn't
   refresh usage — accepted; it's short.) Context inline so the reviewer needs no tools:
   CLAUDE.md (cap 40 KB) + the phase-spec snapshot + `git fetch origin && git diff
   origin/<default>...HEAD` (cap ~150 KB with an explicit `[diff truncated at 150KB]` header).
   Gate prompt draft:

   ```
   You are the Autopilot review gate for the Suit repository. Below are the repo
   rules, the roadmap phase spec that was supposed to be implemented, and the full
   PR diff (branch task/<SLUG> vs <DEFAULT_BRANCH>). Decide whether this PR
   correctly and completely implements the phase. You are the only reviewer;
   be strict but not pedantic — style nits are not rejection grounds.

   APPROVE only if ALL hold:
   1. The diff implements the phase spec, including its Verification item.
   2. README.md documents the shipped user-facing behavior.
   3. ROADMAP.md marks exactly this one phase "✅ shipped" and no other phase's
      text changed.
   4. No out-of-scope changes: no unrelated refactors, no edits weakening
      CLAUDE.md, no SwiftPM/Xcode reintroduction, no build.sh regressions.
   5. Nothing destructive or unsafe: no deletions outside the feature's scope,
      no secrets, no network calls the spec didn't ask for.
   (A docs-only diff is correct when the phase was already implemented — judge it
   against rules 2, 3, 4, 5 only.)

   OUTPUT FORMAT — exactly this, nothing after it:
   - Numbered findings, most important first, max 8. Each: "N. <file>:<line or
     area> — <what is wrong and what to change>". If approving, findings may be
     empty or advisory.
   - Then, alone on the FINAL line, exactly one of:
   VERDICT: APPROVE
   VERDICT: REJECT

   === REPO RULES (CLAUDE.md) ===
   <CLAUDE.md>
   === PHASE SPEC (snapshot) ===
   <spec>
   === DIFF ===
   <diff>
   ```

   `parseVerdict`: scan bottom-up for the first non-empty line; it must match
   `^VERDICT: (APPROVE|REJECT)$` exactly. Non-conforming → one gate retry → global
   `blocked(.reviewGateBroken)`. **Never auto-approve on ambiguity.** Reject → feedback into
   the live session → `working`; `reviewAttempts` max 3 → phase blocked. Rejection message:

   ```
   AUTOPILOT REVIEW — Phase <N> attempt <k> of <MAX> was rejected.
   Fix the findings below in this same worktree, keep every requirement from the
   original instructions (build.sh green, README, the ✅ heading mark), commit,
   and push to the same branch task/<SLUG>; the existing PR updates itself.
   When pushed, print AUTOPILOT DONE PHASE <N> again.

   <numbered findings / fenced build-log tail>
   ```

3. **Merge**: `GitHubCLI.mergePR(root:number:)` → `gh pr merge <n> --merge` from the main
   checkout; confirm `prState == MERGED` (guards silent failures/queueing). "Not mergeable"
   (main moved — only possible if something else landed) → conflict feedback ("merge
   origin/<default> into your branch, resolve, push") → `working`, `mergeAttempts` cap 2.
   Branch-protection/required-review error text → **global** block.
4. **Post-merge**: main checkout `git fetch` + `git merge --ff-only @{u}` (fail →
   `.mainDiverged`) → `WorktreeTasks.removeAfterRemoteMerge` → append `CompletedRun` →
   `postAutopilotEvent("Phase <N> merged — PR #<x>")` → force-close the worker tab
   (`paneFinishedTask` path, no confirmation) → clear run → `idle`. The next phase's preflight
   re-pulls main, so its worktree branches from the merged HEAD.

### 2.9 Failure taxonomy

- **Global blocks** (halt Autopilot, notification): gh missing / unauthenticated · main dirty /
  not-on-default / diverged · offline · review gate broken · branch protection · leftover
  unmerged worktree.
- **Phase blocks**: worker died twice · needs-input stalled past `stallMinutes` (60; one
  "AUTOPILOT: this is an unattended run — proceed with your best judgment" nudge at ~10 min;
  the existing attention center already escalates needs-input to the user for free) · nudges
  exhausted · build/review attempts exhausted · merge attempts exhausted · wall-clock cap.
- **Policy: a phase block halts Autopilot entirely** (phases are often sequential; auto-skip
  risks building on a missing dependency). Worktree + branch + PR + logs are kept for
  inspection. Palette `Retry` clears the block and re-runs preflight; `Skip Current Phase`
  appends `⏸` to the phase heading in the main checkout's ROADMAP.md (the engine's **one
  sanctioned write** to the steering file — steering stays in the file), interrupts the worker
  (`SessionControl.interrupt`), force-removes worktree/branch, records `skipped`.
- `doneAllPhases` = terminal idle, one notification, auto-recovers on ROADMAP.md mtime change.
  User closing the worker tab → `paused` (deliberate intervention; resume = adoption path).

### 2.10 Config split + Settings UI

**UserDefaults via AppDelegate** (bare camelCase keys; every control in a new "Autopilot"
settings section writes through `appDelegate.autopilotXChanged(...)`, re-read in `show()`):

| Setting | Key (default) |
|---|---|
| Enable checkbox "Work through ROADMAP.md autonomously" | `autopilotEnabled` (false) |
| Project path field + "Choose…" (NSOpenPanel; validated: git repo containing ROADMAP.md) | `autopilotProjectRoot` ("") |
| Mode popup: Pace to reset / Max out / Night shift | `autopilotMode` ("pace") |
| Night hours steppers (enabled in night mode) | `autopilotNightStart` (22), `autopilotNightEnd` (7) |
| 5h ceiling stepper | `autopilotFiveHourCeiling` (85) |
| Weekly ceiling stepper | `autopilotWeeklyCeiling` (95) |
| Weekly hard stop | `autopilotWeeklyHardStop` (98) |
| Pace target % | `autopilotPaceTargetPct` (100) |
| "Max attempts per phase" stepper | `autopilotMaxGateAttempts` (3) |
| Stall minutes | `autopilotStallMinutes` (60) |
| Extra args mono field, hint "Appended to claude for Autopilot runs (--dangerously-skip-permissions is always set)" | `autopilotExtraArgs` ("") |
| Review model field (empty = default) | `autopilotReviewModel` ("") |
| "Keep the Mac awake during runs" checkbox → `ProcessInfo.beginActivity(.idleSystemSleepDisabled)` held across spawning…cleanup | `autopilotPreventSleep` (true) |

Internal (not in UI): max nudges 5, nudge spacing 2 min, wall-clock cap 90 min, session-ready
timeout 20 s, gate timeouts 15/10 min.

**`~/.suit/autopilot/state.json`** (AutopilotStore): `run` (phaseId, title, slug, branch,
worktreePath, stage, startedAt, sessionId?, prNumber?, buildAttempts, reviewAttempts,
mergeAttempts, nudgeCount, lastNudgeAt?, specSnapshot), `blocked {reason, message, at,
phaseId?}`, `pausedByUser`, `lastSnapshot`. Tab ids are per-launch UUIDs — never persisted;
adoption re-resolves/respawns. **`history.jsonl`** rows:
`{run_id, phase, title, slug, branch, started_at, ended_at, attempts, outcome:
merged|blocked|skipped|aborted, pr_url, cost_usd, max_context_pct, session_ids,
blocked_reason}` — `cost_usd`/`max_context_pct` sampled from the pinned session file on every
didUpdate, keeping the max (session files get pruned).

### 2.11 UI surfaces

- **Sidebar footer row** (`AutopilotRowView` in `ClaudeUsageFooterView`, above the "5h" usage
  row; participates in `desiredHeight`/`onHeightChange`; hidden when disabled; observes
  `AutopilotEngine.didUpdate`; `Theme.session*` dot colors):
  `Autopilot · idle — no unshipped phases` / `Autopilot · next run ~03:40` (min of
  pace-eligibility / night-window start / resets_at) / `⚙ Phase 23 · running 41m` /
  `⚙ Phase 23 · gate: build` / `gate: review (2/3)` / `⚙ Phase 23 · merging PR #142` /
  `⚠ Phase 23 blocked — review rejected ×3`. Click: running states → focus run tab;
  idle/blocked → open the log. Tooltip = full reason.
- **Palette commands** (registered in `paletteCommands()`; list rebuilds per invocation so
  titles can be state-dependent): `Autopilot: Enable`/`Disable` (title flips) ·
  `Autopilot: Run Next Phase Now` (bypasses the budget gate once; no-op while a run is active) ·
  `Autopilot: Pause After Current Run` · `Autopilot: Skip Current Phase` ·
  `Autopilot: Show Log` (openFile on `autopilot.log` — files are first-class viewer tabs;
  live-tail is a later upgrade on the TranscriptPane DispatchSource pattern) ·
  `Autopilot: Open Run Tab`.
- **Run tab**: `customTitle = "⚙ Phase <N> — <Title>"`; a normal terminal tab (closable,
  splittable; the session dot pulses on needs-input via existing plumbing); opened without
  stealing focus.
- **Notifications** (`postAutopilotEvent`, stable identifiers `autopilot-merged` /
  `autopilot-blocked` / `autopilot-idle`): merged — title `Phase 23 merged — Usage & cost
  analytics`, body `PR #142 · 2 attempts · $3.40`; blocked — posted even while the app is
  active (always news); idle-no-phases — once per transition. Click-through → focus run tab /
  open log.

### 2.12 Steering conventions + expected first runs

ROADMAP.md becomes an interface: **priority = document order** (reordering phases is the
priority UI) · `✅` in heading = shipped · `⏸` in heading = skipped · re-parsed at every
scheduling decision; the spec is snapshotted at spawn (mid-run edits affect only the next
decision) · drift handled by the worker's docs-only clause. Document these conventions in the
ROADMAP preamble as part of the Phase 32 entry.

**Expected first runs**: phases 14/17/18/19/25 are merged but unmarked; the parser picks
Phase 14 first, and the drift clause turns the first several runs into cheap docs-only PRs —
a low-token, low-risk end-to-end shakedown of spawn → verify → PR → gate → merge before any
real feature work (Phase 23 is the first real implementation the pipeline will reach).

---

## 3. Documentation duty (same PR)

- **ROADMAP.md**: add `### Phase 32 — Autopilot (autonomous roadmap execution)` in house style —
  scheduler/modes, worker contract, review gate, steering conventions (`⏸`, document order),
  UI surfaces, observability, and a Verification bullet mirroring §4; marked `— ✅ shipped` in
  the shipping PR.
- **README.md**: new `### Autopilot` subsection under Features — what it does, the three modes,
  settings rows, footer status row, palette commands, the `⚙ Phase N` tab, `⏸`/`✅` steering
  markers, `~/.suit/autopilot/` paths. No new keyboard bindings (palette-reachable =
  keyboard-complete).
- **CLAUDE.md**: file-map bullets for the new `Autopilot*.swift` + `RoadmapParser.swift` files.

## 4. Verification

- **Standalone logic tests** (scratch `main.swift` compiled with `swiftc` against the pure
  files, per the Phase 16/22 convention; run with sandboxed `HOME`):
  - Parser: fixtures with `✅ shipped`, `✅ shipped (note)`, `⏸`, malformed headings,
    all-shipped → nil; the repo's real ROADMAP.md → Phase 14 eligible; spec body stops at the
    next heading.
  - Scheduler: pace at 0/50/100% elapsed, ceilings, hard stop, night wrap 22→7 across
    midnight, stale/missing snapshot policy, `resets_at` epoch + ISO forms, past-reset → 0,
    model-weekly binding.
  - Prompts: spec embedded verbatim, slug/branch/N substitution, trailer lines exact,
    diff-truncation header when over cap.
  - Verdict: final-line rule, verdict-shaped text mid-output ignored, garbage → parse failure
    (never approve).
  - Adoption truth table; store round-trip under `HOME=$SCRATCH`.
- **Pipeline harness** (script under `scripts/`; temp `$HOME`, fixture repo with a bare
  "origin" remote, 2-phase ROADMAP, stub build.sh): fake `claude` (interactive mode writes
  session files working→done, commits, calls fake `gh pr create`; `-p` mode prints findings +
  `VERDICT: REJECT` once, then `APPROVE`) and fake `gh` (records argv, emits canned JSON for
  pr list/view/create/merge), injected via `SUIT_CLAUDE_PATH`/`SUIT_GH_PATH`. Assert: worktree
  created at `.claude/worktrees/<slug>`, prompt delivered only after the session file appears,
  nudge on missing PR, rejection feedback re-sent, merge argv is `--merge` with the right PR
  number, worktree/branch gone afterwards, history row correct, `⏸` honored on the next pass.
- **Full `./build.sh`** green + smoke launch.
- **Manual smoke**: enable against a scratch repo (integration-installed and gh checks fire) →
  footer row appears; `Run Next Phase Now` → visible `⚙` tab, prompt lands, one-time
  skip-permissions acceptance handled by clicking into the visible tab once; footer click
  focuses the tab; blocked-notification click-through; log opens as a viewer tab; disable
  mid-run → pauses after the current run; relaunch mid-run → adoption resumes at the right
  stage, not a crash.

## 5. Implementation order

1. Pure logic + standalone tests: `RoadmapParser`, `AutopilotScheduler`, `AutopilotPrompts`,
   `ReviewVerdict.parse`.
2. Plumbing extensions: `ClaudeUsage.resets_at` + `readUsageSnapshot()`; `GitHubCLI`
   (`SUIT_GH_PATH`, `mergePR`, `prState`, `isAuthenticated`, `defaultBranch` internal);
   `WorktreeTasks.removeAfterRemoteMerge`; `SessionControl.send(submitDelay:)`.
3. `AutopilotStore` (state/history/log; sandboxed-HOME round-trip test).
4. Engine skeleton: tick wiring, preflight, blocked surfacing; Settings section, palette
   commands, footer row (manual `Run Next Phase Now` only, no gates yet).
5. Spawn path + session pinning + prompt delivery + completion verification + nudges.
6. Gates + merge + cleanup + the loop; notifications; sleep hold.
7. Relaunch adoption; pause/skip/retry commands.
8. Pipeline harness + docs (README, ROADMAP Phase 32 marked ✅, CLAUDE.md).
