# ROADMAP

Autopilot trust campaign: make the autonomous loop safe to leave running. Every
phase below came out of an audit of the shipped Autopilot code and is quoted
from it — these are real wedges, not speculative polish. The theme is that
Autopilot currently fails in ways that cost a worker round (or the whole run)
and then sit there needing a human. Phases in priority order; Autopilot steers
off this file (see `RoadmapParser.swift` for the heading grammar).

Order rationale: Phase 1 fixes the prompt every later worker reads, so it goes
first. Phases 2–3 are why the loop can't start; 4–6 are why a started run
wedges; 7–9 are correctness inside a run; 10–12 are the long tail.

### Phase 1 — Worker prompt and review gate name the docs that exist

Every worker prompt sends the model to files that no longer hold what the
prompt claims. `AutopilotPrompts.swift:32` opens with:

> First read CLAUDE.md and follow every convention in it (plain swiftc via
> ./build.sh, no SwiftPM/Xcode, vendor any dependency as source, document
> shipped features in README.md).

`CLAUDE.md` has been a 5-line stub since `edf86ce` ("docs: make AGENTS.md the
single source of agent guidance") — the conventions live in `AGENTS.md`. And
`AGENTS.md:193` now says features are documented in `docs/features.md`, with
`README.md` kept lean ("touch it only when a change belongs in Highlights or
that table"). So a worker that obeys the prompt bloats README.md and never
reads the real rules; a worker that obeys AGENTS.md trips review rule 2.

- Required output 3 (`AutopilotPrompts.swift:39`) becomes `docs/features.md`
  updated in the matching section, with README.md touched **only** when the
  change belongs in Highlights or the shortcuts table.
- The convention line (`:32`) points at `AGENTS.md`, not `CLAUDE.md`.
- Review gate APPROVE rule 2 (`AutopilotPrompts.swift:235`) —
  "README.md documents the shipped user-facing behavior" — becomes
  `docs/features.md`, matching the new required output. Rule 4's "no edits
  weakening CLAUDE.md" becomes AGENTS.md.
- Sweep the same file for any other `CLAUDE.md`/`README.md` reference that
  meant "the conventions" or "the feature reference".

Bootstrap note for whoever runs this phase: the app reviewing your PR is the
*currently built* binary, so your own review still runs the old rule 2. Document
this phase in `docs/features.md` per AGENTS.md, and say plainly in the PR body
that the phase's whole point is moving that target — so rule 2 reads as
satisfied.

Verification: `scripts/autopilot-harness.sh` passes, and a grep of
`AutopilotPrompts.swift` for `CLAUDE.md` and `README.md` returns only the
intentional Highlights/shortcuts carve-out.

effort: low

### Phase 2 — The instructions file: a configurable roadmap path

Autopilot can only ever read `<root>/ROADMAP.md`. `RoadmapParser.swift:41`:

```swift
// The roadmap's one canonical location: <root>/ROADMAP.md. Call sites
// never rebuild the path by hand, so the filename can't drift.
static func path(inRoot root: String) -> String { root + "/ROADMAP.md" }
```

That hardcoding reaches the UI: the Settings project field rejects — beeps and
snaps back — any repo without a root ROADMAP.md (`AppDelegate+Autopilot.swift:46`),
and `AutopilotManager.startHere` returns `.noRoadmap` (`AutopilotManager.swift:142`).
A repo that keeps its plan at `docs/roadmap.md` or names it `PLAN.md` cannot be
configured at all, and this very repo couldn't be between `d673c0c` and this
roadmap landing.

Make the instructions file an explicit, per-project choice rather than a
filename convention Autopilot guesses at:

- A per-project roadmap path setting (relative to the project root, defaulting
  to `ROADMAP.md`), persisted alongside the other per-project Autopilot state
  in `AutopilotStore`. `path(inRoot:)` is already the single choke point — keep
  it that way; it takes the configured path rather than a literal.
- Settings ▸ Autopilot grows the field next to the project picker, with a
  **Choose…** button (`NSOpenPanel`, files only, scoped to the project root)
  so picking the instructions file is a normal file-picker gesture rather than
  typing a path. A path outside the project root is rejected with the reason
  shown, not a beep.
- Validation moves from "does ROADMAP.md exist" to "does the configured file
  exist and parse into at least one phase" — and when it doesn't, the field
  says which of the two failed. `startHere`'s `.noRoadmap` message names the
  configured path.
- The worker prompt's required output 4 and the review gate both name the
  configured file rather than the literal `ROADMAP.md`, since the worker has to
  mark the phase shipped in whatever file the run actually steers off.

Verification: `scripts/roadmap-routing-test.sh` covers `path(inRoot:)` against a
custom relative path, a default, and a rejected escaping path (`../../etc`);
a project configured with a non-default instructions file completes a phase
end-to-end in `scripts/autopilot-harness.sh`.

### Phase 3 — Roadmap discovery recovers by itself

A missing instructions file is a permanent, silent stop. `AutopilotEngine+Preflight.swift:148`:

```swift
guard let roadmap = try? String(contentsOfFile: RoadmapParser.path(inRoot: root), encoding: .utf8) else {
    return .blocked(.noProject, "ROADMAP.md not found in \(root).")
}
```

and the run loop parks there (`AutopilotEngine+RunLoop.swift:41`):

```swift
case .off, .blocked:
    break // blocked waits for the user (Run Next Phase Now retries)
```

Note the asymmetry the code already establishes: `doneAllPhases` stats the
roadmap's mtime every 10 s and re-arms itself (`checkDoneAllPhasesRecovery`),
but the missing-file block has no equivalent — writing the roadmap back does
nothing until someone clicks Retry. The same nil-file hole exists in the other
direction at `AutopilotEngine+RunLoop.swift:192`:

```swift
guard let mtime = roadmapModificationDate() else { return }
```

If the roadmap disappears while the engine sits in `doneAllPhases`, that guard
returns forever while the tooltip keeps promising "editing the roadmap re-arms
Autopilot" (`AutopilotEngine+Status.swift:23`) — a recovery that cannot happen.

- Give the missing roadmap its own reason code. `AutopilotEngineTypes.swift:24`
  admits the current conflation outright: `case noProject = "no-project" // §2.3
  step 1 (also: ROADMAP.md missing)` — three distinct causes on one code is why
  there's nowhere to hang the recovery.
- Poll for the file's *appearance* on the existing 10 s heartbeat, mirroring
  `checkDoneAllPhasesRecovery`, and re-arm when it shows up.
- The `doneAllPhases` → file-vanished transition moves to the new blocked
  reason instead of silently staying idle, so the status text stops lying.

Verification: `scripts/autopilot-harness.sh` gains a case that deletes the
roadmap mid-idle (expect the new blocked reason), writes it back (expect
re-arm without user input), and one that starts with no roadmap at all and
recovers when the file appears.

### Phase 4 — Leftover checks use local HEAD; finish never leaves a conflicted merge

Two independent git bugs, both ending with a wedged main checkout.

**The leftover check tests the wrong ref.** Worktrees are branched from local
`HEAD` (`createTask` → `["worktree", "add", "-b", branch, directory, "HEAD"]`),
but preflight asks whether the branch is an ancestor of *origin*
(`AutopilotEngine+Preflight.swift:199`):

```swift
if case .success = WorktreeTasks.runGit(root, ["merge-base", "--is-ancestor", branch, "origin/\(defaultBranch)"]) {
    mergedIntoDefault = true
}
```

When local main carries commits origin doesn't, a pristine never-worked leftover
branch fails the check and blocks with "has unmerged or uncommitted work — merge
or remove it manually", with no auto-recovery. `WorktreeTasks.swift:139` says
that divergence is routine *here*:

> this repo runs a local-first `main` alongside an integrate-main job that lands
> the same content under different SHAs, so `main` and `origin/main` routinely
> diverge

And `AutopilotEngine+Preflight.swift:104` explicitly relies on the block *not*
firing ("the fresh worktree is fully merged + clean, so the next preflight
auto-cleans it") — true only when `main == origin/main` exactly. Test against
local `HEAD` (accepting either ref, so a pushed-and-merged branch still cleans).

**`finish` abandons a conflicted merge.** `WorktreeTasks.swift:91`:

```swift
if case .failure(let error) = runGit(root, ["merge", "--no-ff", branch, "-m", "Merge \(branch)"]) {
    return "Merge failed: \(error.message)"
}
```

No `merge --abort`, so a conflicting "Finish task" (from `GitView+Worktrees.swift:116`
and `Pane.swift:353`) leaves the user's main checkout in a conflicted MERGING
state with a one-line error — and Autopilot's next preflight then trips
`.mainDirty`. The sibling 60 lines down already shows the house discipline
(`WorktreeTasks.swift:155`): `// Leave the checkout clean if the merge stopped
on conflicts.` → `_ = runGit(root, ["merge", "--abort"])`. Do the same, and say
in the returned message that the merge was rolled back.

Verification: harness cases for (a) a leftover branch on a local-only commit —
expect auto-clean, not a block; (b) `finish(merge:)` into a conflicting main —
expect the error string *and* `git status` clean, no MERGE_HEAD.

### Phase 5 — Build gate verifies build.sh up front

`AutopilotGates.swift:119` hardcodes the build command:

```swift
executable: worktree + "/build.sh", arguments: [], cwd: worktree,
```

and `AutopilotEngine+Gates.swift:55` routes a launch failure through the
*build-failure* path:

```swift
case .failedToLaunch(let message):
    failure = "./build.sh couldn't launch: \(message)"
```

That consumes an attempt and tells the worker to go fix the build — over and
over, until `.buildAttemptsExhausted`. Since "Start Here" accepts any git repo,
a repo with no `build.sh` (or a non-executable one) is guaranteed to burn every
attempt and then block, having spent real money on workers that never had a
chance. The review gate directly above (`AutopilotEngine+Gates.swift:94`) shows
the right shape for exactly this case: a missing binary rolls the attempt back
and blocks immediately with its own reason.

- Preflight checks `build.sh` exists and is executable, blocking with a distinct
  reason that names the file before any worker spawns.
- `.failedToLaunch` stops consuming build attempts: roll the attempt back and
  block with the same reason, matching the review gate's precedent.

Verification: harness case for a project with no `build.sh` — expect a block
before spawn, attempts unconsumed, and the reason naming `build.sh`.

### Phase 6 — A cancelled spawn cleans up the worktree it created

`AutopilotEngine+Preflight.swift:74`:

```swift
let result = WorktreeTasks.createTask(projectRoot: root, name: phase.slug)
DispatchQueue.main.async {
    guard let self else { return }
    self.endBackgroundJob(job)
    guard gen == self.generation, case .idle = self.state else { return }
```

By the time that guard runs, `createTask` has already checked out a full tree
and created `task/<slug>` on disk. If the user pauses or disables in that window
(bumping `generation`), the result is dropped and **nothing removes the
worktree** — no `store.run` owns it, no cleanup path knows about it. It's left
for the next preflight, which per Phase 4 may block rather than clean. The
`guard let self else { return }` above it drops the same way.

Remove the worktree on the dropped path (or restructure so the cancellation is
handled rather than returned past), and log the cleanup — a silently orphaned
worktree is exactly the state Phase 4 is trying to stop producing.

Verification: harness case that cancels during the spawn window — expect no
leftover `.claude/worktrees/<slug>` and no leftover `task/<slug>` branch.

### Phase 7 — Verification tells "roadmap unreadable" from "phase not marked"

`AutopilotEngine+Session.swift:154` folds a missing file into "worker forgot":

```swift
var marked = false
if let roadmap = try? String(contentsOfFile: RoadmapParser.path(inRoot: worktree), encoding: .utf8),
   let phase = RoadmapParser.phase(numbered: run.phaseId, in: roadmap) {
    marked = phase.shipped
}
if !marked {
    missing.append("ROADMAP.md: append \" — ✅ shipped\" to this phase's heading")
}
```

If the worker deletes, renames, or restructures the roadmap — precisely what
`d673c0c` did to this repo — `marked` is false forever, so the engine nudges 5
times (≥2 min apart), hits `.nudgesExhausted`, blocks, and leaves the worktree.
The nudge text actively misleads: it tells the worker to fix a heading in a file
that isn't there. Split the two cases — file unreadable / phase number absent /
present-but-unmarked — and give the first two their own message naming the real
problem. (This phase must respect Phase 2's configured path.)

Verification: harness cases for a worker that deletes the roadmap and one that
renames the phase heading — each expects its own distinct message, not the
"append ✅ shipped" nudge.

### Phase 8 — Merge gate splits conflict rounds from transient failures

`AutopilotEngine+Merge.swift:107` counts unrelated things together:

```swift
// Anything else (auth blip, network, API hiccup): retry on the merge
// poll pace, with the same small cap so a persistent failure blocks.
let attempts = run.mergeAttempts + 1
store.updateRun { $0.mergeAttempts = attempts }
if attempts > Self.mergeConflictCap {
```

With a cap of 2, one genuine conflict round plus two network blips — or three
blips alone — blocks a run whose PR is perfectly mergeable, and the message says
"gh pr merge kept failing" when nothing was ever wrong with the merge. The
review gate already solved this: it keeps a separate `reviewGateBrokenCount`
(`AutopilotEngine+Gates.swift:236`) precisely so infrastructure hiccups don't
eat the *semantic* attempt budget. Mirror it — a conflict counter and an
infrastructure counter, each with its own cap and its own block message.

Verification: harness cases for three consecutive transient failures followed by
a success (expect merge, no block) and for repeated real conflicts (expect a
block whose message says conflict).

### Phase 9 — Shipped and skipped markers anchor to the heading tail

`RoadmapParser.swift:74` treats a marker anywhere as status:

```swift
shipped: containsMarker(line, shippedScalar),
```

The header comment states it plainly (`RoadmapParser.swift:4`): "a ✅ anywhere
in a phase heading means shipped". So `### Phase 7 — Render ✅ marks in the
sidebar` is born shipped, never runs, and nothing warns — and `cleanTitle`
truncates the title at the marker, so the phase's own name is silently mangled
(here, to "Render"), which also changes its slug and branch.

Anchor the marker to the heading's tail — where `markingPhaseSkipped` already
writes it — while keeping the "✅ shipped (note)" parenthetical variants working,
since those are load-bearing for roadmap-drift PRs (`AutopilotPrompts.swift:52`).
This is a grammar change to a file the whole engine steers off: keep it pure,
keep it Foundation-only, and lean on the harness.

Verification: `scripts/roadmap-routing-test.sh` pins a mid-title ✅ as *not*
shipped with its title intact, plus the existing tail forms — bare, `— ✅ shipped`,
`— ✅ shipped (docs-only: …)`, and `⏸ skipped` — still parsing as today.

### Phase 10 — Per-repo worker prompt override

`AutopilotPrompts.swift:32` bakes this repo's conventions into every worker on
every repo — "plain swiftc via ./build.sh, no SwiftPM/Xcode, vendor any
dependency as source" — and required outputs 2 and 3 hardcode `./build.sh` and
the feature docs. "Start Here" happily launches on a Rust or Python repo and
then tells the worker not to use SwiftPM. The only escape hatch today is
`~/.suit/autopilot-prompt.md` (`AutopilotPrompts.swift:80`), which is **global** —
so with `AutopilotManager` now running N repos at once, you cannot have per-repo
templates at all.

Add a per-repo override at `.claude/autopilot-prompt.md` in the project root,
slotting into the existing lookup ahead of the global file and the built-in
default (repo → global → built-in, first hit wins). Version-controlled with the
repo it describes, which is the point. Document the precedence and the
substitution tokens in `docs/features.md`.

Verification: harness case pinning the three-level precedence, including a repo
override that shadows a present global one.

### Phase 11 — Autopilot notifications get per-repo identifiers

`AppDelegate+Autopilot.swift:189` uses a compile-time constant:

```swift
identifier: "autopilot-blocked")
```

`"autopilot-blocked"`, `"autopilot-merged"` and `"autopilot-idle"` go straight
to `UNNotificationRequest(identifier:)` (`ClaudeAttention.swift:144`), which
**replaces** any pending notification with the same id. That was correct when
there was one Autopilot; `AutopilotManager` now runs several concurrently, so
repo B's block silently erases repo A's unread block banner — the exact case
notifications exist for. The sibling directly below already documents the fix
pattern (`ClaudeAttention.swift:147`): "Budget-trip notifications: a per-trip
identifier (so a distinct crossing is its own banner, not a replacement)". Key
by project root plus event, and title the banner with the repo so two blocked
repos are tellable apart at a glance.

Verification: harness case asserting two projects blocking in sequence produce
two distinct identifiers.

### Phase 12 — Wire the four orphaned harnesses in, and let CI run the slow suite

`AGENTS.md:52` is unambiguous: "When you add such logic, follow the pattern, add
a harness script for it, and wire it into the `HARNESSES` list in
`scripts/test.sh`." Four harnesses exist on disk, still compile live source, and
are in no list — so nothing has ever run them:

- `scripts/background-tasks-test.sh` (`896ebb2`, background-task monitor)
- `scripts/commit-graph-harness.sh` (`6ff4f06`, commit graph pane)
- `scripts/isolation-harness.sh` (`30bc2be`, per-session worktree isolation)
- `scripts/symbol-index-test.sh` (`bd85ae4`, go-to-definition & find-references)

`test.sh:8` claims it "runs them all from one place so an agent has a single 'run
the tests' command" and `test.sh:19` promises "0 if every harness passed, 1 if
any failed or a harness is missing" — neither is true today, and CI
(`.github/workflows/swift.yml:28`) inherits the hole.

- Add all four to `HARNESSES`, each `fast` unless it measurably isn't; fix
  whatever bitrotted rather than registering a failing script (report it in the
  PR body if a harness turns out to be testing something that no longer exists).
- `.github/workflows/swift.yml` runs `scripts/test.sh --all`, so the Autopilot
  pipeline harness — the most complex subsystem, one that writes files, merges
  branches and spends money — is finally gated on something. Keep the fast suite
  as its own step so a fast failure reports fast.
- While in that file: its line 3 comment points at CLAUDE.md for "Why no
  SwiftPM", which `edf86ce` moved to `AGENTS.md`. One-line fix, same file.

Verification: `scripts/test.sh --list` shows all four; `scripts/test.sh` exits 0
with them registered; `--all` runs the autopilot harness in CI.

model: haiku
effort: low
