import Darwin
import Foundation

// The Autopilot engine (ROADMAP Phase 32): the main-queue state machine that
// works through ROADMAP.md autonomously. Ticked every 3 s off AppDelegate's
// existing sessionRefreshTimer, it throttles everything internally: the budget
// decision runs every tick from the cached usage snapshot (no I/O beyond it),
// the ROADMAP.md mtime is stat'ed ~every 10 s, git/gh preflight polls are
// ≥30 s apart and stage-scoped, and a single `inFlight` flag prevents
// overlapping background work. Blocking git/gh work runs on a global queue and
// hops back to main; a monotonic `generation` token (bumped on every state
// transition) drops callbacks that started under an older state.
//
// Shipped so far: preflight + budget scheduling; the full worker-run
// `working` stage — spawn (worktree → run tab → two-stage prompt delivery on
// session-ready), §2.7 completion verification against world state with
// targeted nudges, and the watchdogs (session-ready timeout, dead-worker
// respawn with --continue, needs-input stall, 90-min wall clock); and the
// §2.8 gate + merge pipeline — build gate (log-tail feedback on failure),
// headless review gate (rejection findings feedback; broken gate = one retry
// then a global block), `gh pr merge` with MERGED confirmation (conflict
// feedback, branch-protection block), and post-merge cleanup (main-checkout
// ff-sync, worktree removal, history row, notification, tab close) looping
// back to `idle`. Relaunch adoption (§2.2's truth table — a persisted run is
// re-resolved against GitHub and resumed at the right stage, respawning
// `claude --continue` for the working stage) shares one path with the
// resume/retry commands; Skip Current Phase appends ⏸ to the phase heading
// (the engine's one sanctioned ROADMAP.md write) and records `skipped`.

// §2.2 engine states. `running` reads its run detail from AutopilotStore
// (the store is the persisted source of truth; the enum only carries what
// distinguishes states).
enum AutopilotEngineState: Equatable {
    case off                              // setting disabled
    case idle                             // enabled, between runs
    case running                          // a run is in flight (stage in store.run)
    case paused                           // user asked to pause; run record kept
    case blocked(AutopilotBlockReason)    // halted until the user intervenes
    case doneAllPhases                    // every phase shipped/skipped; auto-recovers on ROADMAP edit
}

// §2.3's distinct preflight failures plus the §2.9 failure taxonomy. The
// rawValue is what AutopilotStore.Blocked persists, so it must stay stable.
enum AutopilotBlockReason: String, Equatable {
    // Global blocks (halt Autopilot; environment/repo problems).
    case noProject = "no-project"                       // §2.3 step 1 (also: ROADMAP.md missing)
    case ghMissing = "gh-missing"                       // §2.3 step 3 — expected first-run state
    case ghUnauthenticated = "gh-unauthenticated"       // §2.3 step 4
    case mainNotOnDefault = "main-not-on-default"       // §2.3 step 5
    case mainDirty = "main-dirty"                       // §2.3 step 6
    case offline = "offline"                            // §2.3 step 7 (fetch failed)
    case mainDiverged = "main-diverged"                 // §2.3 step 7 (no fast-forward)
    case leftoverWorktree = "leftover-worktree"         // §2.3 step 8 (unmerged leftovers)
    case reviewGateBroken = "review-gate-broken"        // §2.8 (unparseable verdict / missing claude)
    case branchProtection = "branch-protection"         // §2.8 merge step
    // Phase blocks (this phase failed; policy §2.9 halts Autopilot anyway).
    case spawnFailed = "spawn-failed"                   // worktree/tab creation failed
    case sessionNeverReady = "session-never-ready"      // §2.5 20 s session-file timeout
    case workerDied = "worker-died"                     // died twice (§2.7 watchdog)
    case stalled = "stalled"                            // needs-input past stallMinutes
    case nudgesExhausted = "nudges-exhausted"           // §2.7 max nudges
    case buildAttemptsExhausted = "build-attempts-exhausted"
    case reviewAttemptsExhausted = "review-attempts-exhausted"
    case mergeAttemptsExhausted = "merge-attempts-exhausted"
    case wallClockExceeded = "wall-clock-exceeded"      // 90 min per-attempt cap
    case workerReportedBlocked = "worker-reported-blocked" // §2.7 Autopilot-Blocked PR trailer
    // A persisted reason this build doesn't know (older/newer state.json).
    case other = "other"

    // §2.9: global blocks are environment problems (fix them and every phase
    // can proceed); phase blocks name a failed run. Policy-wise both halt
    // Autopilot — the split only drives messaging.
    var isGlobal: Bool {
        switch self {
        case .noProject, .ghMissing, .ghUnauthenticated, .mainNotOnDefault,
             .mainDirty, .offline, .mainDiverged, .leftoverWorktree,
             .reviewGateBroken, .branchProtection:
            return true
        default:
            return false
        }
    }
}

// §2.2 run stages, persisted to state.json as `AutopilotRun.stage` rawValues.
// `preflight`/`spawning` are deliberately absent: they are transient and never
// persisted (a relaunch mid-preflight just re-runs it).
enum AutopilotRunStage: String {
    case working
    case gatingBuild = "gating-build"
    case gatingReview = "gating-review"
    case merging
    case cleanup
}

// What preflight (§2.3, ordered) concluded — computed on a background queue,
// consumed on main.
enum AutopilotPreflightResult {
    case ready(RoadmapPhase)
    case doneAllPhases
    case blocked(AutopilotBlockReason, String)
}

// What the sidebar footer row shows (§2.11): the status line, the full reason
// as tooltip, and a coarse kind the row maps to Theme.session* dot colors.
struct AutopilotFooterStatus {
    enum Kind {
        case idle, running, blocked, paused, done
    }
    let text: String
    let tooltip: String
    let kind: Kind
}

// NSObject for the selector-based NotificationCenter observation below.
final class AutopilotEngine: NSObject {
    static let shared = AutopilotEngine()
    static let didUpdate = Notification.Name("AutopilotEngineDidUpdate")

    // Set once in applicationDidFinishLaunching; the engine reads its §2.9
    // settings (enabled, project root, mode, ceilings, …) through it live.
    weak var appDelegate: AppDelegate?

    private(set) var state: AutopilotEngineState = .off
    // Bumped on every state transition; background completions capture it at
    // launch and drop themselves when it moved on (§2.1).
    private(set) var generation = 0

    // Whether the footer row shows at all — hidden while the setting is off.
    var isActive: Bool {
        if case .off = state { return false }
        return true
    }

    private let store = AutopilotStore.shared

    // MARK: - Tick throttles (§2.4 last paragraph)

    // The one flag preventing overlapping background work (preflight,
    // verification, gates, merge, cleanup, adoption). Token-owned: every job
    // takes a fresh token at start, and a completion releases the flag only
    // while it still holds the newest one — a stale callback (about to be
    // dropped by the generation check anyway) must never free a hold a newer
    // job acquired after it, e.g. a mid-verification block → palette Retry →
    // adoption, whose gh lookup would otherwise race a second verification.
    private var inFlight = false
    private var backgroundJobToken = 0

    private func beginBackgroundJob() -> Int {
        inFlight = true
        backgroundJobToken += 1
        return backgroundJobToken
    }

    private func endBackgroundJob(_ token: Int) {
        if token == backgroundJobToken { inFlight = false }
    }

    // §2.2 adoption in flight: the persisted run's true stage is still being
    // resolved against GitHub, so the per-tick stage dispatcher must not
    // drive the (possibly stale) persisted stage meanwhile.
    private var adopting = false
    // git/gh polls ≥30 s apart, scoped per stage; idle's poll is preflight.
    private static let gitPollInterval: TimeInterval = 30
    private var lastPreflightAt: Date?
    // ROADMAP.md mtime stat ~every 10 s (doneAllPhases auto-recovery).
    private static let roadmapCheckInterval: TimeInterval = 10
    private var lastRoadmapCheckAt: Date?
    private var roadmapMtimeAtDone: Date?

    // "Run Next Phase Now": bypass the budget gate for the next tick only.
    private var budgetBypassOnce = false

    // MARK: - Worker-run plumbing (§2.5–§2.7)

    // The worker tab. A per-launch UUID — never persisted (§2.10); relaunch
    // adoption re-resolves or respawns. Exposed for AppDelegate's
    // focusAutopilotRunTab and the tabProcessDidExit intercept.
    private(set) var workerTabId: String?
    // §2.5: no matching session file within 20 s of the launch → blocked
    // (covers the one-time --dangerously-skip-permissions acceptance dialog).
    private static let sessionReadyTimeout: TimeInterval = 20
    private var sessionReadyDeadline: Date?
    // The next session-ready delivery sends the resume prompt (post-respawn)
    // instead of the full worker instructions.
    private var deliverResumePrompt = false
    // Gate feedback that couldn't reach a live session (the shell died during
    // the gates, or an adopted run never had a tab): delivered on the next
    // session-ready in place of the resume prompt — `--continue` restores the
    // conversation, so the feedback itself is the resume.
    private var pendingFeedbackMessage: String?
    // §2.7 watchdogs: one respawn with --continue per run, a second death
    // blocks; each attempt gets its own 90-min wall clock.
    private var respawnCount = 0
    private var attemptStartedAt: Date?
    private static let wallClockCap: TimeInterval = 90 * 60
    private static let frozenSessionAge: TimeInterval = 30 * 60
    // §2.7 completion verification: session `done` only triggers it, world
    // state decides; throttled ≥30 s like the other git/gh polls.
    private static let verificationInterval: TimeInterval = 30
    private var lastVerificationAt: Date?
    private static let maxNudges = 5
    private static let nudgeSpacing: TimeInterval = 2 * 60
    // §2.9 needs-input stall: one best-judgment nudge at ~10 min, blocked
    // past autopilotStallMinutes.
    private static let stallNudgeAfter: TimeInterval = 10 * 60
    private var needsInputSince: Date?
    private var stallNudgeSent = false

    // MARK: - Gate + merge memory (§2.8; in-memory, reset at spawn/cleanup)

    // A broken review gate (timeout / unparseable verdict / failed diff) gets
    // exactly one retry, then a global block — never an auto-approve.
    private var reviewGateBrokenCount = 0
    // The running gate's process handle (build.sh / claude -p), so Skip
    // Current Phase can kill it before force-removing the worktree it runs in.
    private var activeGateHandle: AutopilotGateHandle?
    // `gh pr merge` succeeded but the PR hasn't read MERGED yet (merge queue):
    // subsequent merge-stage ticks only re-poll prState, never re-merge.
    private var mergeConfirmedPending = false
    // Merge-stage polls (retries + MERGED confirmation) share the ≥30 s pace.
    private var lastMergePollAt: Date?
    // §2.8 step 3: "not mergeable" conflict feedback rounds are capped at 2.
    private static let mergeConflictCap = 2
    // §2.9 "Keep the Mac awake during runs": held across spawning…cleanup.
    private var sleepActivity: NSObjectProtocol?

    // The cached usage snapshot the budget math runs on every tick — refreshed
    // when ClaudeSessionMonitor reloads (file events + the 30 s heartbeat),
    // seeded from state.json on launch so a relaunch can still show
    // "next run ~03:40" before fresh usage arrives.
    private var cachedSnapshot: UsageSnapshot?
    private(set) var lastDecision: AutopilotScheduleDecision?

    // The human line behind the current block, for the footer tooltip.
    private var blockedMessage: String?

    // Repaint trigger: didUpdate is posted whenever the composed footer text
    // changes (elapsed-minutes drift included), not on every tick.
    private var lastStatusText = ""

    private override init() {
        super.init()
        // Observing by name doesn't instantiate the monitor — safe even though
        // the engine singleton can be created early (the sidebar footer).
        NotificationCenter.default.addObserver(
            self, selector: #selector(sessionMonitorUpdated(_:)),
            name: ClaudeSessionMonitor.didUpdate, object: nil
        )
    }

    // MARK: - Launch

    // Called once from applicationDidFinishLaunching (after the session
    // monitor exists). App quit kills pty children, so a live worker never
    // survives a relaunch — a persisted run is re-adopted per §2.2's truth
    // table (reactivateFromStore → adoptPersistedRun); persisted pause/block
    // flags win over adoption (the user's last word stands until Resume or
    // Retry, which re-adopt the kept run themselves).
    func adoptOnLaunch() {
        guard let app = appDelegate, app.autopilotEnabled else {
            setState(.off)
            return
        }
        seedSnapshotFromStore()
        refreshSnapshot()
        reactivateFromStore()
        store.log("Autopilot active — \(describe(state))")
    }

    // MARK: - Tick (main queue, every 3 s)

    func tick() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let app = appDelegate else { return }
        guard app.autopilotEnabled else {
            if isActive { setState(.off) }
            return
        }
        if case .off = state {
            // Just (re-)enabled: restore paused/blocked from the store.
            reactivateFromStore()
        }

        switch state {
        case .off, .blocked:
            break // blocked waits for the user (Run Next Phase Now retries)
        case .paused:
            break
        case .doneAllPhases:
            checkDoneAllPhasesRecovery()
        case .running:
            tickRunning()
        case .idle:
            tickIdle()
        }

        // Repaint the footer only when its text actually changed.
        let status = footerStatus()
        if status.text != lastStatusText {
            lastStatusText = status.text
            postUpdate()
        }
    }

    private func tickIdle() {
        guard let app = appDelegate else { return }
        if store.pausedByUser {
            setState(.paused)
            return
        }
        let decision = AutopilotScheduler.mayStartRun(
            mode: app.autopilotMode, snapshot: cachedSnapshot,
            now: Date(), config: schedulerConfig
        )
        if decision != lastDecision {
            lastDecision = decision
            postUpdate()
        }
        let bypass = budgetBypassOnce
        if case .wait = decision, !bypass { return }
        startPreflightIfDue(force: bypass)
    }

    // The per-tick run driver: a pull-based dispatcher over the persisted run
    // stage. The gate/merge/cleanup starters are all idempotent-per-tick —
    // the shared `inFlight` flag (and the merge poll pace) keeps each stage's
    // background work single-file.
    private func tickRunning() {
        // Mid-adoption the persisted stage may be stale (the truth table is
        // still resolving what actually happened) — don't drive it yet.
        guard !adopting else { return }
        guard let run = store.run else {
            // A running state with no persisted run can't happen through the
            // normal paths; recover instead of wedging.
            workerTabId = nil
            setState(.idle)
            return
        }
        switch AutopilotRunStage(rawValue: run.stage) {
        case .working:
            tickWorking(run)
        case .gatingBuild:
            maybeStartBuildGate(run)
        case .gatingReview:
            maybeStartReviewGate(run)
        case .merging:
            maybeStartMerge(run)
        case .cleanup:
            maybeStartCleanup(run)
        case nil:
            // A stage this build doesn't know (newer state.json) — leave it
            // for the user rather than guessing.
            break
        }
    }

    // The `working` stage driver: session readiness, watchdogs, stall
    // handling, and re-arming completion verification.
    private func tickWorking(_ run: AutopilotRun) {
        // The user closing the worker tab is deliberate intervention (§2.9):
        // park instead of respawning over their decision.
        if workerTabId != nil, workerTerminal() == nil {
            workerTabId = nil
            store.setPausedByUser(true)
            store.log("worker tab was closed — Autopilot paused (Run Next Phase Now resumes)")
            setState(.paused)
            return
        }

        // §2.5: no session file within the ready timeout → blocked, tab left
        // open (the one-time skip-permissions dialog is the usual culprit).
        if run.sessionId == nil {
            if let deadline = sessionReadyDeadline, Date() >= deadline {
                sessionReadyDeadline = nil
                block(.sessionNeverReady,
                      "claude session never became ready — check the run tab",
                      phaseId: run.phaseId)
            }
            return
        }

        // 90-min per-attempt wall clock (§2.7); tab left open for inspection.
        if let started = attemptStartedAt,
           Date().timeIntervalSince(started) > Self.wallClockCap {
            block(.wallClockExceeded,
                  "Phase \(run.phaseId): the attempt passed the 90-minute wall clock — check the run tab",
                  phaseId: run.phaseId)
            return
        }

        let session = pinnedSession(run)

        // §2.9 needs-input stall handling.
        if let session, session.state == .needsInput {
            handleStall(run: run, session: session)
            if case .blocked = state { return }
        } else {
            needsInputSince = nil
        }

        // §2.7 watchdog: claude's pid is gone but the shell (and tab) live
        // on, and the session file froze — the worker died silently.
        if let session, let pid = session.pid, Self.processIsDead(pid),
           Date().timeIntervalSince(session.updatedAt) > Self.frozenSessionAge {
            workerDied(reason: "session pid \(pid) is dead and the session file froze")
            return
        }

        // Re-trigger verification while the session sits at `done` — the
        // ≥30 s throttle or the nudge spacing may have deferred the last one
        // past the final didUpdate.
        if session?.state == .done {
            maybeStartVerification()
        }
    }

    // MARK: - Preflight (§2.3; blocking git/gh work on a background queue)

    private func startPreflightIfDue(force: Bool) {
        guard !inFlight else { return }
        if !force, let last = lastPreflightAt,
           Date().timeIntervalSince(last) < Self.gitPollInterval { return }
        lastPreflightAt = Date()
        budgetBypassOnce = false
        let job = beginBackgroundJob()
        let gen = generation
        let root = appDelegate?.autopilotProjectRoot ?? ""
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = AutopilotEngine.runPreflight(root: root)
            DispatchQueue.main.async {
                guard let self else { return }
                self.endBackgroundJob(job)
                // Stale: the state moved on (disabled, paused, …) while the
                // git/gh work ran.
                guard gen == self.generation, case .idle = self.state else { return }
                self.handlePreflight(result)
            }
        }
    }

    private func handlePreflight(_ result: AutopilotPreflightResult) {
        switch result {
        case .doneAllPhases:
            store.log("preflight: every ROADMAP.md phase is shipped or skipped — idle until the roadmap changes")
            roadmapMtimeAtDone = roadmapModificationDate() ?? Date()
            lastRoadmapCheckAt = nil
            // §2.11: once per transition — handlePreflight only runs from
            // `idle`, so entering doneAllPhases is exactly that transition.
            appDelegate?.postAutopilotNotification(
                title: "Autopilot idle — no unshipped phases",
                body: "Every ROADMAP.md phase is ✅ shipped or ⏸ skipped. Editing the roadmap re-arms Autopilot.",
                identifier: "autopilot-idle"
            )
            setState(.doneAllPhases)
        case .blocked(let reason, let message):
            block(reason, message, phaseId: nil)
        case .ready(let phase):
            store.log("preflight passed for Phase \(phase.number) — \(phase.title)")
            spawnRun(for: phase)
        }
    }

    // MARK: - Spawn (§2.5 launch stage)

    // Worktree creation on a background queue (git worktree add checks out a
    // full tree — too slow for main), then run record + tab on main.
    private func spawnRun(for phase: RoadmapPhase) {
        guard !inFlight, let app = appDelegate else { return }
        let root = app.autopilotProjectRoot
        let job = beginBackgroundJob()
        // §2.9: the sleep hold spans spawning…cleanup. Spawning happens while
        // the state is still `idle`, so it's taken explicitly here;
        // updateSleepHold (run on every state transition) keeps it through
        // `running` and releases it anywhere else.
        beginSleepHoldForSpawn()
        let gen = generation
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // createTask re-slugs the name it is given; RoadmapPhase.slug is a
            // fixed point of that function, so worktree/branch match the run.
            let result = WorktreeTasks.createTask(projectRoot: root, name: phase.slug)
            DispatchQueue.main.async {
                guard let self else { return }
                self.endBackgroundJob(job)
                guard gen == self.generation, case .idle = self.state else { return }
                switch result {
                case .failure(let error):
                    self.block(.spawnFailed,
                               "Couldn't create the task worktree for “\(phase.slug)”: \(error.message)",
                               phaseId: phase.number)
                case .success(let directory):
                    self.startRun(phase: phase, worktreePath: directory)
                }
            }
        }
    }

    private func startRun(phase: RoadmapPhase, worktreePath: String) {
        // The spec snapshot makes the run immune to concurrent ROADMAP.md
        // edits — worker and review gate judge against the same artifact.
        let run = AutopilotRun(
            phaseId: phase.number, title: phase.title, slug: phase.slug,
            branch: phase.branch, worktreePath: worktreePath,
            stage: AutopilotRunStage.working.rawValue,
            startedAt: Date().timeIntervalSince1970,
            specSnapshot: phase.specText
        )
        store.setRun(run)
        respawnCount = 0
        reviewGateBrokenCount = 0
        mergeConfirmedPending = false
        lastMergePollAt = nil
        guard openWorkerTab(run: run, continueSession: false) else {
            // Nothing real happened yet: drop the run record; the fresh
            // worktree is fully merged + clean, so the next preflight
            // auto-cleans it.
            store.setRun(nil)
            block(.spawnFailed, "No window is available to host the run tab.", phaseId: phase.number)
            return
        }
        store.log("run started: Phase \(phase.number) — \(phase.title) in \(worktreePath)")
        setState(.running)
    }

    // Opens the worker tab (fresh spawn, or the --continue respawn) and arms
    // the §2.5 session-ready watch. Returns false when no window exists.
    private func openWorkerTab(run: AutopilotRun, continueSession: Bool) -> Bool {
        guard let tab = appDelegate?.openAutopilotRunTab(
            directory: run.worktreePath,
            title: "⚙ Phase \(run.phaseId) — \(run.title)",
            continueSession: continueSession
        ) else { return false }
        workerTabId = tab.id
        deliverResumePrompt = continueSession
        sessionReadyDeadline = Date().addingTimeInterval(Self.sessionReadyTimeout)
        attemptStartedAt = Date()
        needsInputSince = nil
        stallNudgeSent = false
        lastVerificationAt = nil
        return true
    }

    // The full ordered §2.3 checklist. Pure with respect to engine state so it
    // can run on any queue; every step shells out to git/gh and may block.
    static func runPreflight(root: String) -> AutopilotPreflightResult {
        // 1. Project configured + a git repo.
        guard !root.isEmpty else {
            return .blocked(.noProject, "No Autopilot project is configured — choose one in Settings ▸ Autopilot.")
        }
        guard FileIndex.gitRoot(of: root) != nil else {
            return .blocked(.noProject, "\(root) is not a git repository.")
        }
        // 2. ROADMAP.md exists and still has an eligible phase.
        guard let roadmap = try? String(contentsOfFile: root + "/ROADMAP.md", encoding: .utf8) else {
            return .blocked(.noProject, "ROADMAP.md not found in \(root).")
        }
        guard let phase = RoadmapParser.eligiblePhase(in: roadmap) else {
            return .doneAllPhases
        }
        // 3. gh installed.
        guard GitHubCLI.isAvailable else {
            return .blocked(.ghMissing, "Install the gh CLI — brew install gh, then gh auth login.")
        }
        // 4. gh authenticated.
        guard GitHubCLI.isAuthenticated(root: root) else {
            return .blocked(.ghUnauthenticated, "gh isn't authenticated — run gh auth login.")
        }
        // 5. Main checkout on the default branch (createTask branches from its HEAD).
        guard let defaultBranch = GitHubCLI.defaultBranch(root: root) else {
            return .blocked(.mainNotOnDefault, "Couldn't resolve the repo's default branch.")
        }
        let current = WorktreeTasks.currentBranch(root)
        guard current == defaultBranch else {
            return .blocked(.mainNotOnDefault, "The main checkout is on “\(current ?? "?")”, not “\(defaultBranch)” — a new task worktree would branch from the wrong HEAD.")
        }
        // 6. Main checkout clean.
        guard !WorktreeTasks.hasUncommittedChanges(root) else {
            return .blocked(.mainDirty, "The main checkout has uncommitted changes — commit or stash them.")
        }
        // 7. Up to date with origin.
        if case .failure(let error) = WorktreeTasks.runGit(root, ["fetch", "origin"]) {
            return .blocked(.offline, "git fetch origin failed: \(error.message)")
        }
        if case .failure(let error) = WorktreeTasks.runGit(root, ["merge", "--ff-only", "@{u}"]) {
            return .blocked(.mainDiverged, "The main checkout can't fast-forward to origin/\(defaultBranch): \(error.message)")
        }
        // 8. No leftover worktree/branch for this phase's slug. Auto-clean only
        // when the branch is fully merged into origin's default and the
        // worktree is clean — anything else may hold unshipped work, and a
        // human decides.
        let slug = phase.slug
        let branch = phase.branch
        let worktreePath = root + "/" + WorktreeTasks.worktreesSubpath + "/" + slug
        let worktreeExists = FileManager.default.fileExists(atPath: worktreePath)
        var branchExists = false
        if case .success = WorktreeTasks.runGit(root, ["rev-parse", "--verify", "-q", "refs/heads/\(branch)"]) {
            branchExists = true
        }
        if worktreeExists || branchExists {
            var mergedIntoDefault = true
            if branchExists {
                mergedIntoDefault = false
                if case .success = WorktreeTasks.runGit(root, ["merge-base", "--is-ancestor", branch, "origin/\(defaultBranch)"]) {
                    mergedIntoDefault = true
                }
            }
            let worktreeClean = !worktreeExists || !WorktreeTasks.hasUncommittedChanges(worktreePath)
            guard mergedIntoDefault, worktreeClean else {
                return .blocked(.leftoverWorktree, "A leftover worktree/branch for “\(slug)” has unmerged or uncommitted work — merge or remove it manually.")
            }
            if worktreeExists {
                if let error = WorktreeTasks.removeAfterRemoteMerge(worktreePath: worktreePath) {
                    return .blocked(.leftoverWorktree, "Couldn't clean up the leftover worktree for “\(slug)”: \(error)")
                }
            } else if case .failure(let error) = WorktreeTasks.runGit(root, ["branch", "-D", branch]) {
                return .blocked(.leftoverWorktree, "Couldn't delete the leftover branch \(branch): \(error.message)")
            }
        }
        return .ready(phase)
    }

    // MARK: - Relaunch adoption (§2.2)

    // §2.2's adoption truth table, factored pure so it's truth-table
    // testable: where a persisted run resumes, given whether its worktree
    // still exists and what GitHub says about its PR. nil = nothing real
    // happened (no PR, no worktree) — the run is cleared. The
    // "was merging && OPEN → retry merge" refinement is the caller's (it
    // needs the persisted stage).
    static func adoptionStage(worktreeExists: Bool, prState: GitPRInfo.State?) -> AutopilotRunStage? {
        switch prState {
        case .merged:
            // The PR landed; only the post-merge cleanup can still be owed.
            return .cleanup
        case .open:
            // Gates are idempotent — re-run both against the open PR.
            return .gatingBuild
        case .closed, .none:
            // A closed-unmerged PR counts as no PR: finishing the work and
            // (re-)opening one is the working stage's job. No worktree
            // either → nothing real happened.
            return worktreeExists ? .working : nil
        }
    }

    // The one path back into a persisted run: relaunch (adoptOnLaunch),
    // Resume after a pause, Retry after a block, and re-enabling the setting
    // all land here. Resolves world state on a background queue, then
    // finishAdoption lands the run at its true stage.
    private func adoptPersistedRun(context: String) {
        guard let app = appDelegate, let run = store.run else {
            setState(.idle)
            return
        }
        let root = app.autopilotProjectRoot
        guard !root.isEmpty else {
            block(.noProject, "No Autopilot project is configured — choose one in Settings ▸ Autopilot.", phaseId: nil)
            return
        }
        store.log("\(context): adopting the persisted Phase \(run.phaseId) run (stage \(run.stage))")
        setState(.running)
        adopting = true
        let job = beginBackgroundJob()
        let gen = generation
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // §2.2: without gh the PR's state is unknowable — blocked(.ghMissing),
            // run kept; Retry adopts it once gh is installed. Probed here, not
            // on main: the first isAvailable touch can fall back to a login
            // shell, and adoption runs inside applicationDidFinishLaunching.
            guard GitHubCLI.isAvailable else {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.endBackgroundJob(job)
                    self.adopting = false
                    guard gen == self.generation, case .running = self.state else { return }
                    self.block(.ghMissing,
                               "Install the gh CLI — brew install gh, then gh auth login. The persisted Phase \(run.phaseId) run is kept and resumes once gh is available.",
                               phaseId: nil)
                }
                return
            }
            // The PR's state on GitHub: by number when the run recorded one
            // (gh pr view sees merged/closed PRs and distinguishes "couldn't
            // reach GitHub" from "no PR"), else by branch from the all-state
            // PR list (nil there genuinely means no PR ever got opened).
            var prState: GitPRInfo.State?
            var prNumber = run.prNumber
            var lookupError: String?
            if let number = run.prNumber {
                switch GitHubCLI.prState(root: root, number: number) {
                case .success(let detail): prState = detail.state
                case .failure(let error): lookupError = "couldn't read PR #\(number) (\(error.message))"
                }
            } else if let pr = GitHubCLI.pullRequests(root: root)[run.branch] {
                prState = pr.state
                prNumber = pr.number
            }
            let worktreeExists = FileManager.default.fileExists(atPath: run.worktreePath)
            DispatchQueue.main.async {
                guard let self else { return }
                self.endBackgroundJob(job)
                self.adopting = false
                guard gen == self.generation, case .running = self.state,
                      let current = self.store.run, current.id == run.id else { return }
                if let lookupError {
                    self.block(.offline, "Adoption couldn't reach GitHub — \(lookupError). Retry once you're online.", phaseId: nil)
                    return
                }
                self.finishAdoption(run: current, worktreeExists: worktreeExists,
                                    prState: prState, prNumber: prNumber)
            }
        }
    }

    private func finishAdoption(run: AutopilotRun, worktreeExists: Bool,
                                prState: GitPRInfo.State?, prNumber: Int?) {
        guard let stage = Self.adoptionStage(worktreeExists: worktreeExists, prState: prState) else {
            // §2.2: no PR and no worktree — nothing real happened; clear the
            // run and let the next preflight start the phase over.
            store.log("adoption: no PR and no worktree for \(run.branch) — clearing the run")
            store.setRun(nil)
            resetRunMemory()
            lastPreflightAt = nil
            setState(.idle)
            return
        }
        // §2.2: a run that was mid-merge and whose PR is still OPEN retries
        // the merge (idempotent) instead of re-running the gates.
        var target = stage
        if target == .gatingBuild, AutopilotRunStage(rawValue: run.stage) == .merging {
            target = .merging
        }
        resetRunMemory()
        store.updateRun { r in
            r.stage = target.rawValue
            if r.prNumber == nil { r.prNumber = prNumber }
            // Un-pin the dead session so the session-ready watch re-arms;
            // the old id stays in sessionIds for the history row.
            if target == .working { r.sessionId = nil }
        }
        if target == .working {
            // §2.2 respawn: `claude --dangerously-skip-permissions --continue`
            // + the resume prompt, delivered on session-ready like a fresh
            // spawn.
            guard let current = store.run, openWorkerTab(run: current, continueSession: true) else {
                block(.workerDied,
                      "Phase \(run.phaseId): no window could host the adopted run's tab",
                      phaseId: run.phaseId)
                return
            }
            store.log("adoption: Phase \(run.phaseId) resumes at working — respawned claude --continue")
        } else {
            store.log("adoption: Phase \(run.phaseId) resumes at stage \(target.rawValue)")
        }
        postUpdate()
    }

    // MARK: - doneAllPhases auto-recovery (the steering loop)

    private func checkDoneAllPhasesRecovery() {
        let now = Date()
        if let last = lastRoadmapCheckAt,
           now.timeIntervalSince(last) < Self.roadmapCheckInterval { return }
        lastRoadmapCheckAt = now
        guard let mtime = roadmapModificationDate() else { return }
        if let atDone = roadmapMtimeAtDone, mtime > atDone {
            store.log("ROADMAP.md changed — re-checking for eligible phases")
            roadmapMtimeAtDone = nil
            setState(.idle)
        }
    }

    private func roadmapModificationDate() -> Date? {
        guard let root = appDelegate?.autopilotProjectRoot, !root.isEmpty else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: root + "/ROADMAP.md")
        return attributes?[.modificationDate] as? Date
    }

    // MARK: - Session pinning + prompt delivery (§2.5 inject stage)

    // The statusline writes the session file as soon as the TUI renders, so
    // file-appears ≡ ready-for-input. The session must live in the run's
    // worktree (cwd unique per run) and the assigner's pid-ancestry check
    // confirms it actually runs under the worker tab's shell; the freshness
    // guard keeps a stale file from an earlier run in the same worktree from
    // pinning before the new claude has rendered.
    private func tryPinWorkerSession(_ run: AutopilotRun) {
        guard let terminal = workerTerminal() else { return }
        let assigner = ClaudeSessionMonitor.shared.makeAssigner()
        guard let session = assigner.session(forShellPid: terminal.shellPid, cwd: run.worktreePath),
              session.cwd == run.worktreePath,
              let started = attemptStartedAt,
              session.updatedAt >= started - 1 else { return }
        store.updateRun { r in
            r.sessionId = session.id
            if !r.sessionIds.contains(session.id) { r.sessionIds.append(session.id) }
        }
        sessionReadyDeadline = nil
        let prompt: String
        if let pending = pendingFeedbackMessage {
            // Held gate feedback (returnRunToWorking had no live session):
            // `--continue` restored the conversation, so the feedback itself
            // is the resume.
            prompt = pending
        } else if deliverResumePrompt {
            prompt = AutopilotPrompts.resumePrompt(
                phase: run.phaseId, title: run.title, slug: run.slug,
                worktreePath: run.worktreePath
            )
        } else {
            prompt = AutopilotPrompts.workerPrompt(
                phase: run.phaseId, title: run.title, slug: run.slug,
                worktreePath: run.worktreePath, specSnapshot: run.specSnapshot
            )
        }
        pendingFeedbackMessage = nil
        deliverResumePrompt = false
        // 0.5 s submit delay: the multi-KB bracketed paste must be fully
        // consumed before the CR (§2.5).
        SessionControl.send(text: prompt, to: terminal, submit: true, submitDelay: 0.5)
        store.log("worker session \(session.id.prefix(8))… ready — instructions delivered")
        postUpdate()
    }

    // §2.10: keep the max cost/context on the run record, written through
    // only when a value actually grows (didUpdate fires on every statusline
    // render — not worth a state.json rewrite each time).
    private func sampleSessionMetrics(_ session: ClaudeSession, run: AutopilotRun) {
        let cost = session.costUSD ?? 0
        let context = session.contextPct ?? 0
        let costGrew = cost > (run.costUSD ?? 0)
        let contextGrew = context > (run.maxContextPct ?? 0)
        guard costGrew || contextGrew else { return }
        store.updateRun { r in
            if costGrew { r.costUSD = cost }
            if contextGrew { r.maxContextPct = context }
        }
    }

    // MARK: - Completion verification (§2.7 — the Stop-hook trap, addressed)

    // What the world-state checklist concluded — computed on a background
    // queue, consumed on main.
    enum VerificationOutcome {
        case complete(prNumber: Int)
        case missing([String])          // the specific unmet required outputs
        case workerBlocked(String)      // the PR body carried Autopilot-Blocked:
    }

    private func maybeStartVerification() {
        guard !inFlight else { return }
        if let last = lastVerificationAt,
           Date().timeIntervalSince(last) < Self.verificationInterval { return }
        guard let run = store.run, let root = appDelegate?.autopilotProjectRoot,
              !root.isEmpty else { return }
        lastVerificationAt = Date()
        let job = beginBackgroundJob()
        let gen = generation
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let outcome = AutopilotEngine.runCompletionVerification(root: root, run: run)
            DispatchQueue.main.async {
                guard let self else { return }
                self.endBackgroundJob(job)
                guard gen == self.generation, case .running = self.state,
                      let current = self.store.run, current.id == run.id,
                      AutopilotRunStage(rawValue: current.stage) == .working else { return }
                self.handleVerification(outcome, run: current)
            }
        }
    }

    // The five §2.7 world-state checks. Pure with respect to engine state so
    // it can run on any queue; every step shells out to git/gh and may block.
    static func runCompletionVerification(root: String, run: AutopilotRun) -> VerificationOutcome {
        var missing: [String] = []
        let worktree = run.worktreePath
        let defaultBranch = GitHubCLI.defaultBranch(root: root) ?? "main"

        // 1. Commits ahead of the default branch.
        var aheadCount = 0
        if case .success(let out) = WorktreeTasks.runGit(worktree, ["rev-list", "--count", "origin/\(defaultBranch)..HEAD"]) {
            aheadCount = Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
        if aheadCount == 0 {
            missing.append("commits on \(run.branch) — the branch has nothing ahead of \(defaultBranch)")
        }

        // 2. Branch pushed: the remote-tracking ref exists and matches HEAD
        // (the worker pushes from inside the shared repo, which updates it).
        var pushed = false
        if case .success(let remote) = WorktreeTasks.runGit(worktree, ["rev-parse", "--verify", "-q", "refs/remotes/origin/\(run.branch)"]),
           case .success(let head) = WorktreeTasks.runGit(worktree, ["rev-parse", "HEAD"]),
           remote.trimmingCharacters(in: .whitespacesAndNewlines) == head.trimmingCharacters(in: .whitespacesAndNewlines),
           !head.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pushed = true
        }
        if !pushed {
            missing.append("git push -u origin \(run.branch) — origin doesn't have the latest commits")
        }

        // 3. An open PR for the branch whose body carries the phase trailer;
        // an Autopilot-Blocked trailer instead means the worker gave up.
        var prNumber: Int?
        if let pr = GitHubCLI.pullRequests(root: root)[run.branch], pr.state == .open {
            switch GitHubCLI.prState(root: root, number: pr.number) {
            case .failure(let error):
                missing.append("a readable PR body — gh pr view #\(pr.number) failed (\(error.message))")
            case .success(let detail):
                if let reason = trailerValue("Autopilot-Blocked", in: detail.body) {
                    return .workerBlocked(reason)
                }
                if trailerValue("Autopilot-Phase", in: detail.body) == String(run.phaseId) {
                    prNumber = pr.number
                } else {
                    missing.append("the PR body must END with exactly \"Autopilot-Phase: \(run.phaseId)\" and \"Autopilot-Slug: \(run.slug)\" — fix it with gh pr edit \(pr.number) --body")
                }
            }
        } else {
            missing.append("an open PR for \(run.branch) — gh pr create per the original instructions")
        }

        // 4. Worktree clean.
        if WorktreeTasks.hasUncommittedChanges(worktree) {
            missing.append("a clean worktree — commit (or remove) the uncommitted changes")
        }

        // 5. The worktree's ROADMAP.md marks this phase shipped.
        var marked = false
        if let roadmap = try? String(contentsOfFile: worktree + "/ROADMAP.md", encoding: .utf8),
           let phase = RoadmapParser.phase(numbered: run.phaseId, in: roadmap) {
            marked = phase.shipped
        }
        if !marked {
            missing.append("ROADMAP.md: append \" — ✅ shipped\" to this phase's heading")
        }

        if missing.isEmpty, let prNumber {
            return .complete(prNumber: prNumber)
        }
        return .missing(missing)
    }

    // "Key: value" trailer lines anywhere in a PR body (workers put them
    // last, but gh/web edits can append content below).
    static func trailerValue(_ key: String, in body: String) -> String? {
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(key + ":") {
                return String(trimmed.dropFirst(key.count + 1))
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func handleVerification(_ outcome: VerificationOutcome, run: AutopilotRun) {
        switch outcome {
        case .workerBlocked(let reason):
            block(.workerReportedBlocked,
                  "Phase \(run.phaseId): the worker reported itself blocked — \(reason)",
                  phaseId: run.phaseId)
        case .complete(let prNumber):
            store.updateRun { r in
                r.prNumber = prNumber
                r.stage = AutopilotRunStage.gatingBuild.rawValue
            }
            reviewGateBrokenCount = 0
            mergeConfirmedPending = false
            lastMergePollAt = nil
            store.log("Phase \(run.phaseId) verified complete — PR #\(prNumber) is open; running the gates")
            postUpdate()
        case .missing(let items):
            nudgeWorker(run: run, missing: items)
        }
    }

    // MARK: - Nudges + stall handling (§2.7, §2.9)

    // Nudge the live session with the specific missing items. Each nudge
    // flips the session back to working via the UserPromptSubmit hook, so the
    // done → verify cycle re-arms; ≥2 min apart, max 5 per run → blocked.
    private func nudgeWorker(run: AutopilotRun, missing: [String]) {
        if run.nudgeCount >= Self.maxNudges {
            block(.nudgesExhausted,
                  "Phase \(run.phaseId): still incomplete after \(Self.maxNudges) nudges — missing: \(missing.joined(separator: "; "))",
                  phaseId: run.phaseId)
            return
        }
        // Inside the spacing window: do nothing — the tick's done-state
        // re-verification retries once it elapses.
        if let last = run.lastNudgeAt,
           Date().timeIntervalSince1970 - last < Self.nudgeSpacing { return }
        guard let terminal = workerTerminal() else { return }
        SessionControl.send(
            text: AutopilotPrompts.nudgeMessage(phase: run.phaseId, slug: run.slug, missing: missing),
            to: terminal, submit: true, submitDelay: 0.5
        )
        store.updateRun { r in
            r.nudgeCount += 1
            r.lastNudgeAt = Date().timeIntervalSince1970
        }
        store.log("nudge \(run.nudgeCount + 1)/\(Self.maxNudges) sent — missing: \(missing.joined(separator: " · "))")
    }

    // §2.9: an unattended run has nobody to answer questions — one
    // best-judgment nudge at ~10 min (the attention center already escalates
    // needs-input to the user for free), blocked past stallMinutes.
    private func handleStall(run: AutopilotRun, session: ClaudeSession) {
        let since: Date
        if let existing = needsInputSince {
            since = existing
        } else {
            since = Date()
            needsInputSince = since
        }
        let stalled = Date().timeIntervalSince(since)
        let cap = TimeInterval(appDelegate?.autopilotStallMinutes ?? 60) * 60
        if stalled >= cap {
            block(.stalled,
                  "Phase \(run.phaseId): the worker has needed input for \(Int(stalled / 60)) min — answer it in the run tab",
                  phaseId: run.phaseId)
            return
        }
        if stalled >= Self.stallNudgeAfter, !stallNudgeSent, let terminal = workerTerminal() {
            stallNudgeSent = true
            SessionControl.send(text: AutopilotPrompts.stallNudgeMessage,
                                to: terminal, submit: true, submitDelay: 0.5)
            store.log("stall nudge sent — needs-input for \(Int(stalled / 60)) min")
        }
    }

    // MARK: - Build gate (§2.8 step 1)

    // Free and first: the worktree's own ./build.sh, streamed to
    // logs/<slug>/build-<attempt>.log with the gate runner's 15-min watchdog.
    // The attempt is bumped up-front so the footer / feedback / log name all
    // agree on its number.
    private func maybeStartBuildGate(_ run: AutopilotRun) {
        guard !inFlight, let app = appDelegate else { return }
        let attempt = run.buildAttempts + 1
        let maxAttempts = app.autopilotMaxGateAttempts
        store.updateRun { $0.buildAttempts = attempt }
        let logURL = store.buildLogURL(slug: run.slug, attempt: attempt)
        store.log("build gate: attempt \(attempt)/\(maxAttempts) — running ./build.sh in \(run.worktreePath)")
        let job = beginBackgroundJob()
        let gen = generation
        let handle = AutopilotGateHandle()
        activeGateHandle = handle
        AutopilotBuildGate.run(worktree: run.worktreePath, logPath: logURL.path,
                               handle: handle) { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self else { return }
                self.endBackgroundJob(job)
                if self.activeGateHandle === handle { self.activeGateHandle = nil }
                guard gen == self.generation, case .running = self.state,
                      let current = self.store.run, current.id == run.id,
                      AutopilotRunStage(rawValue: current.stage) == .gatingBuild else { return }
                self.handleBuildGate(outcome, run: current, attempt: attempt,
                                     maxAttempts: maxAttempts, logPath: logURL.path)
            }
        }
        postUpdate()
    }

    private func handleBuildGate(_ outcome: AutopilotGateOutcome, run: AutopilotRun,
                                 attempt: Int, maxAttempts: Int, logPath: String) {
        if outcome.cleanExit {
            store.log("build gate passed (attempt \(attempt)) — running the review gate")
            reviewGateBrokenCount = 0
            store.updateRun { $0.stage = AutopilotRunStage.gatingReview.rawValue }
            postUpdate()
            return
        }
        let failure: String
        var logTail = Self.tailOfLog(atPath: logPath)
        switch outcome {
        case .exited(let status):
            failure = "./build.sh exited \(status)"
        case .timedOut:
            failure = "./build.sh timed out after \(Int(AutopilotBuildGate.timeoutSeconds / 60)) minutes"
            logTail = "(\(failure) and was killed)\n" + logTail
        case .failedToLaunch(let message):
            failure = "./build.sh couldn't launch: \(message)"
            logTail = failure
        }
        store.log("build gate failed (attempt \(attempt)/\(maxAttempts)): \(failure)")
        if attempt >= maxAttempts {
            block(.buildAttemptsExhausted,
                  "Phase \(run.phaseId): \(failure) — attempt \(attempt) of \(maxAttempts); log: \(logPath)",
                  phaseId: run.phaseId)
            return
        }
        returnRunToWorking(run, message: AutopilotPrompts.buildFailureMessage(
            phase: run.phaseId, attempt: attempt, maxAttempts: maxAttempts,
            slug: run.slug, logTail: logTail
        ), logLine: "build-failure feedback sent — back to working")
    }

    // MARK: - Review gate (§2.8 step 2)

    // Headless `claude -p` with the whole context inlined (repo rules + the
    // spec snapshot + the PR diff vs a freshly-fetched origin/<default>), the
    // verdict parsed off the output's final non-blank line. Ambiguity is never
    // an approve: a broken gate retries once, then blocks globally.
    private func maybeStartReviewGate(_ run: AutopilotRun) {
        guard !inFlight, let app = appDelegate else { return }
        let attempt = run.reviewAttempts + 1
        let maxAttempts = app.autopilotMaxGateAttempts
        store.updateRun { $0.reviewAttempts = attempt }
        let logURL = store.reviewLogURL(slug: run.slug, attempt: attempt)
        let root = app.autopilotProjectRoot
        let model = app.autopilotReviewModel
        store.log("review gate: attempt \(attempt)/\(maxAttempts) — headless claude review of \(run.branch)")
        let job = beginBackgroundJob()
        let gen = generation
        let handle = AutopilotGateHandle()
        activeGateHandle = handle
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // Probed here, not on main: the first isAvailable touch can fall
            // back to a login shell (seconds of beachball on the main queue).
            guard AutopilotReviewGate.isAvailable else {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.endBackgroundJob(job)
                    if self.activeGateHandle === handle { self.activeGateHandle = nil }
                    guard gen == self.generation, case .running = self.state,
                          let current = self.store.run, current.id == run.id,
                          AutopilotRunStage(rawValue: current.stage) == .gatingReview else { return }
                    // A missing binary never consumes a review attempt.
                    self.store.updateRun { $0.reviewAttempts = max(0, $0.reviewAttempts - 1) }
                    self.block(.reviewGateBroken,
                               "The review gate needs the claude CLI, which couldn't be found (set SUIT_CLAUDE_PATH or install claude).",
                               phaseId: nil)
                }
                return
            }
            let defaultBranch = GitHubCLI.defaultBranch(root: root) ?? "main"
            // Best-effort: verification already fetched recently; a stale
            // origin ref only makes the diff marginally out of date.
            _ = WorktreeTasks.runGit(run.worktreePath, ["fetch", "origin"])
            let diffResult = WorktreeTasks.runGit(
                run.worktreePath, ["diff", "origin/\(defaultBranch)...HEAD"])
            guard case .success(let diff) = diffResult else {
                var why = "couldn't produce the PR diff vs origin/\(defaultBranch)"
                if case .failure(let error) = diffResult { why += " (\(error.message))" }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.endBackgroundJob(job)
                    if self.activeGateHandle === handle { self.activeGateHandle = nil }
                    guard gen == self.generation, case .running = self.state,
                          let current = self.store.run, current.id == run.id,
                          AutopilotRunStage(rawValue: current.stage) == .gatingReview else { return }
                    self.reviewGateFailed(run: current, why: why)
                }
                return
            }
            // Repo rules from the *main* checkout: a worker that weakened
            // CLAUDE.md must be judged against the original, not its edit.
            let claudeMd = (try? String(contentsOfFile: root + "/CLAUDE.md", encoding: .utf8)) ?? ""
            let prompt = AutopilotPrompts.reviewGatePrompt(
                slug: run.slug, defaultBranch: defaultBranch, claudeMd: claudeMd,
                specSnapshot: run.specSnapshot, diff: diff
            )
            AutopilotReviewGate.run(
                worktree: run.worktreePath, prompt: prompt,
                model: model.isEmpty ? nil : model, logPath: logURL.path,
                handle: handle
            ) { outcome, output in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.endBackgroundJob(job)
                    if self.activeGateHandle === handle { self.activeGateHandle = nil }
                    guard gen == self.generation, case .running = self.state,
                          let current = self.store.run, current.id == run.id,
                          AutopilotRunStage(rawValue: current.stage) == .gatingReview else { return }
                    self.handleReviewGate(outcome, output: output, run: current,
                                          attempt: attempt, maxAttempts: maxAttempts,
                                          logPath: logURL.path)
                }
            }
        }
        postUpdate()
    }

    private func handleReviewGate(_ outcome: AutopilotGateOutcome, output: String,
                                  run: AutopilotRun, attempt: Int, maxAttempts: Int,
                                  logPath: String) {
        switch outcome {
        case .failedToLaunch(let message):
            // No retry can fix a missing/unrunnable binary.
            block(.reviewGateBroken, "The review gate couldn't run claude: \(message)", phaseId: nil)
        case .timedOut:
            reviewGateFailed(run: run, why: "the review timed out after \(Int(AutopilotReviewGate.timeoutSeconds / 60)) minutes")
        case .exited(let status) where status != 0:
            reviewGateFailed(run: run, why: "claude -p exited \(status) — see \(logPath)")
        case .exited:
            guard let verdict = ReviewVerdict.parse(output) else {
                reviewGateFailed(run: run, why: "the output's final line wasn't a VERDICT — see \(logPath)")
                return
            }
            switch verdict {
            case .approve:
                store.log("review gate approved (attempt \(attempt)) — merging PR #\(run.prNumber ?? 0)")
                reviewGateBrokenCount = 0
                mergeConfirmedPending = false
                lastMergePollAt = nil
                store.updateRun { $0.stage = AutopilotRunStage.merging.rawValue }
                postUpdate()
            case .reject:
                reviewGateBrokenCount = 0
                store.log("review gate rejected (attempt \(attempt)/\(maxAttempts)) — see \(logPath)")
                if attempt >= maxAttempts {
                    block(.reviewAttemptsExhausted,
                          "Phase \(run.phaseId): the review gate rejected \(attempt) attempts — findings in \(logPath)",
                          phaseId: run.phaseId)
                    return
                }
                var findings = Self.findingsText(from: output)
                if findings.isEmpty { findings = "(the review gate returned no findings — re-check the diff against the phase spec)" }
                returnRunToWorking(run, message: AutopilotPrompts.reviewRejectionMessage(
                    phase: run.phaseId, attempt: attempt, maxAttempts: maxAttempts,
                    slug: run.slug, findings: findings
                ), logLine: "review-rejection feedback sent — back to working")
            }
        }
    }

    // §2.8: one gate retry for a broken review (timeout / unparseable / diff
    // failure), then a *global* block — the gate itself is sick, not the
    // phase. The pre-bumped attempt is rolled back so a hiccup never consumes
    // a review attempt.
    private func reviewGateFailed(run: AutopilotRun, why: String) {
        reviewGateBrokenCount += 1
        if reviewGateBrokenCount >= 2 {
            block(.reviewGateBroken, "The review gate failed twice — \(why)", phaseId: nil)
            return
        }
        store.updateRun { $0.reviewAttempts = max(0, $0.reviewAttempts - 1) }
        store.log("review gate hiccup (\(why)) — retrying once")
    }

    // MARK: - Merge (§2.8 step 3)

    private func maybeStartMerge(_ run: AutopilotRun) {
        guard !inFlight, let app = appDelegate else { return }
        guard let prNumber = run.prNumber else {
            // Can't happen through the normal paths (verification records the
            // PR before the gates) — surface it rather than wedging.
            block(.other, "Phase \(run.phaseId): the run reached merging without a recorded PR number.",
                  phaseId: run.phaseId)
            return
        }
        if let last = lastMergePollAt,
           Date().timeIntervalSince(last) < Self.gitPollInterval { return }
        lastMergePollAt = Date()
        let root = app.autopilotProjectRoot
        let confirmOnly = mergeConfirmedPending
        if confirmOnly {
            store.log("merge: re-checking PR #\(prNumber) state")
        } else {
            store.log("merging PR #\(prNumber) (gh pr merge --merge)")
        }
        let job = beginBackgroundJob()
        let gen = generation
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var mergeError: String?
            if !confirmOnly, case .failure(let error) = GitHubCLI.mergePR(root: root, number: prNumber) {
                mergeError = error.message
            }
            // Confirm the merge actually landed — a queued/silently-failed
            // merge must not reach cleanup (§2.8).
            var merged = false
            if mergeError == nil,
               case .success(let detail) = GitHubCLI.prState(root: root, number: prNumber) {
                merged = detail.state == .merged
            }
            // The conflict feedback names the branch to merge; resolve it
            // here so the main-queue handler never shells out.
            let defaultBranch = mergeError != nil
                ? (GitHubCLI.defaultBranch(root: root) ?? "main") : "main"
            DispatchQueue.main.async {
                guard let self else { return }
                self.endBackgroundJob(job)
                guard gen == self.generation, case .running = self.state,
                      let current = self.store.run, current.id == run.id,
                      AutopilotRunStage(rawValue: current.stage) == .merging else { return }
                if let mergeError {
                    self.handleMergeFailure(mergeError, run: current,
                                            prNumber: prNumber, defaultBranch: defaultBranch)
                } else if merged {
                    self.mergeConfirmedPending = false
                    self.store.log("PR #\(prNumber) confirmed MERGED — cleaning up")
                    self.store.updateRun { $0.stage = AutopilotRunStage.cleanup.rawValue }
                    self.postUpdate()
                } else {
                    // gh accepted the merge but GitHub hasn't marked the PR
                    // MERGED yet (merge queue / eventual consistency): re-poll
                    // the state on the next paced tick, never re-merge.
                    self.mergeConfirmedPending = true
                    self.store.log("gh pr merge succeeded but PR #\(prNumber) isn't MERGED yet — re-checking")
                }
            }
        }
    }

    private func handleMergeFailure(_ message: String, run: AutopilotRun,
                                    prNumber: Int, defaultBranch: String) {
        let lower = message.lowercased()
        // A retry after a server-side success (the first response got lost)
        // errors "already merged": that's a confirmation to chase, not a
        // failure to count.
        if lower.contains("already merged") {
            mergeConfirmedPending = true
            store.log("PR #\(prNumber) reports already merged — confirming")
            return
        }
        // "Not mergeable": the default branch moved under the PR — conflict
        // feedback into the live session, capped at 2 rounds (§2.8).
        if lower.contains("not mergeable") || lower.contains("conflict") {
            let attempts = run.mergeAttempts + 1
            store.updateRun { $0.mergeAttempts = attempts }
            if attempts > Self.mergeConflictCap {
                block(.mergeAttemptsExhausted,
                      "Phase \(run.phaseId): PR #\(prNumber) still isn't mergeable after \(attempts) tries — \(message)",
                      phaseId: run.phaseId)
                return
            }
            store.log("PR #\(prNumber) not mergeable (\(message)) — conflict feedback \(attempts)/\(Self.mergeConflictCap)")
            returnRunToWorking(run, message: AutopilotPrompts.mergeConflictMessage(
                phase: run.phaseId, slug: run.slug, defaultBranch: defaultBranch
            ), logLine: "merge-conflict feedback sent — back to working")
            return
        }
        // Branch protection / required reviews: no amount of retrying or
        // worker feedback fixes repo policy — a human reconfigures it (§2.8).
        if lower.contains("protect") || lower.contains("required") || lower.contains("policy") {
            block(.branchProtection,
                  "gh pr merge #\(prNumber) was refused by branch protection: \(message)",
                  phaseId: nil)
            return
        }
        // Anything else (auth blip, network, API hiccup): retry on the merge
        // poll pace, with the same small cap so a persistent failure blocks.
        let attempts = run.mergeAttempts + 1
        store.updateRun { $0.mergeAttempts = attempts }
        if attempts > Self.mergeConflictCap {
            block(.mergeAttemptsExhausted,
                  "Phase \(run.phaseId): gh pr merge #\(prNumber) kept failing — \(message)",
                  phaseId: run.phaseId)
            return
        }
        store.log("gh pr merge #\(prNumber) failed (\(message)) — retrying (\(attempts)/\(Self.mergeConflictCap))")
    }

    // MARK: - Cleanup + the loop (§2.8 step 4)

    private func maybeStartCleanup(_ run: AutopilotRun) {
        guard !inFlight, let app = appDelegate else { return }
        let root = app.autopilotProjectRoot
        store.log("cleanup: syncing the main checkout and removing the task worktree")
        let job = beginBackgroundJob()
        let gen = generation
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // Main checkout catches up to the merged HEAD first, so the next
            // phase's worktree branches from it.
            var divergedMessage: String?
            if case .failure(let error) = WorktreeTasks.runGit(root, ["fetch", "origin"]) {
                divergedMessage = "post-merge git fetch origin failed: \(error.message)"
            } else if case .failure(let error) = WorktreeTasks.runGit(root, ["merge", "--ff-only", "@{u}"]) {
                divergedMessage = "the main checkout can't fast-forward to the merged HEAD: \(error.message)"
            }
            var removalWarning: String?
            if divergedMessage == nil {
                if FileManager.default.fileExists(atPath: run.worktreePath) {
                    removalWarning = WorktreeTasks.removeAfterRemoteMerge(worktreePath: run.worktreePath)
                } else {
                    // Worktree already gone (manual cleanup): best-effort
                    // branch deletes only.
                    _ = WorktreeTasks.runGit(root, ["branch", "-D", run.branch])
                    _ = WorktreeTasks.runGit(root, ["push", "origin", "--delete", run.branch])
                }
            }
            // For the history row's pr_url; optional, so failures are fine.
            let prURL = GitHubCLI.pullRequests(root: root)[run.branch]?.url
            DispatchQueue.main.async {
                guard let self else { return }
                self.endBackgroundJob(job)
                guard gen == self.generation, case .running = self.state,
                      let current = self.store.run, current.id == run.id,
                      AutopilotRunStage(rawValue: current.stage) == .cleanup else { return }
                if let divergedMessage {
                    self.block(.mainDiverged, divergedMessage, phaseId: nil)
                    return
                }
                if let removalWarning {
                    // Not fatal: the next preflight auto-cleans a merged-and-
                    // clean leftover (§2.3 step 8) — log it and keep looping.
                    self.store.log("cleanup warning: \(removalWarning)")
                }
                self.finishMergedRun(current, prURL: prURL)
            }
        }
    }

    // History row + notification + tab close + clear → idle: the loop
    // continues (the next tick's preflight re-pulls main, so the next phase
    // branches from the merged HEAD).
    private func finishMergedRun(_ run: AutopilotRun, prURL: String?) {
        let attempts = max(run.buildAttempts, run.reviewAttempts, 1)
        store.appendHistory(CompletedRun(
            runId: run.id, phase: run.phaseId, title: run.title, slug: run.slug,
            branch: run.branch, startedAt: run.startedAt,
            endedAt: Date().timeIntervalSince1970, attempts: attempts,
            outcome: .merged, prURL: prURL, costUSD: run.costUSD,
            maxContextPct: run.maxContextPct, sessionIds: run.sessionIds,
            blockedReason: nil
        ))
        var body = "PR #\(run.prNumber ?? 0) · \(attempts) attempt\(attempts == 1 ? "" : "s")"
        if let cost = run.costUSD { body += String(format: " · $%.2f", cost) }
        appDelegate?.postAutopilotNotification(
            title: "Phase \(run.phaseId) merged — \(run.title)",
            body: body, identifier: "autopilot-merged"
        )
        store.log("Phase \(run.phaseId) merged — PR #\(run.prNumber ?? 0)\(prURL.map { " (\($0))" } ?? "")")
        closeWorkerTab()
        store.setRun(nil)
        resetRunMemory()
        // Don't wait out the poll throttle — budget willing, the next phase
        // starts on the next tick.
        lastPreflightAt = nil
        setState(.idle)
    }

    // MARK: - Gate/merge helpers

    // Gate feedback → the live worker session, and the run back to `working`
    // with a fresh fix round (its own wall clock / stall / verification
    // window). Without a live session the feedback is never dropped: an
    // adopted run with no tab respawns `claude --continue` (feedback delivers
    // on session-ready), a shell that died during the gates goes through the
    // §2.7 death path the same way, and only a user-closed tab — deliberate
    // intervention (§2.9) — parks in `paused` via the next working tick.
    private func returnRunToWorking(_ run: AutopilotRun, message: String, logLine: String) {
        store.updateRun { $0.stage = AutopilotRunStage.working.rawValue }
        attemptStartedAt = Date()
        needsInputSince = nil
        stallNudgeSent = false
        // The session file still reads `done` until the UserPromptSubmit hook
        // fires for the feedback; a verification inside that window would see
        // the world all green and skip the gates' verdict. The ≥30 s pace
        // starting now comfortably outlasts the hook.
        lastVerificationAt = Date()
        if let terminal = workerTerminal() {
            SessionControl.send(text: message, to: terminal, submit: true, submitDelay: 0.5)
            store.log(logLine)
        } else if workerTabId == nil {
            // Adoption landed the run at a gate stage without opening a tab
            // (§2.2: OPEN PR → re-run gates). Respawn `claude --continue`
            // (not counted against the §2.7 death respawn) and hold the
            // feedback for session-ready.
            pendingFeedbackMessage = message
            store.updateRun { $0.sessionId = nil }
            guard let current = store.run, openWorkerTab(run: current, continueSession: true) else {
                pendingFeedbackMessage = nil
                block(.workerDied,
                      "Phase \(run.phaseId): no window could host the run tab for the gate feedback",
                      phaseId: run.phaseId)
                return
            }
            store.log("no worker tab (adopted run) — respawned claude --continue; gate feedback delivers on session-ready")
        } else if workerTab() != nil {
            // The tab is open but its shell died during the gates
            // (workerTabExited deliberately leaves gate stages alone): the
            // §2.7 death path respawns `claude --continue`; the feedback
            // delivers on session-ready. A second death blocks instead — the
            // held feedback then dies with the run memory on the next adoption.
            pendingFeedbackMessage = message
            workerDied(reason: "the shell died while the gates ran")
        } else {
            store.log("worker tab was closed — feedback couldn't be delivered (Autopilot will pause)")
        }
        postUpdate()
    }

    // §2.8 item 4: the merged run's worker tab closes without confirmation —
    // the same trust as paneFinishedTask. workerTabId clears first so the
    // teardown's process kill can't route back through the
    // tabProcessDidExit intercept as a worker death.
    private func closeWorkerTab() {
        guard let id = workerTabId else { return }
        workerTabId = nil
        guard let (controller, tab) = appDelegate?.controllerAndTab(withId: id) else { return }
        controller.closeAutopilotRunTab(tab)
    }

    // Clears every per-run in-memory flag once the run record is gone.
    private func resetRunMemory() {
        workerTabId = nil
        sessionReadyDeadline = nil
        deliverResumePrompt = false
        pendingFeedbackMessage = nil
        respawnCount = 0
        attemptStartedAt = nil
        needsInputSince = nil
        stallNudgeSent = false
        lastVerificationAt = nil
        reviewGateBrokenCount = 0
        mergeConfirmedPending = false
        lastMergePollAt = nil
    }

    // The last ~100 lines of a gate log — what rides along in the §2.8
    // build-failure feedback (fenced by AutopilotPrompts, one paste unit).
    private static func tailOfLog(atPath path: String, maxLines: Int = 100) -> String {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return "(no build log was captured)"
        }
        // Only the tail region matters; 64 KB comfortably covers 100 lines.
        let text = String(decoding: data.suffix(64 * 1024), as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(maxLines)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // The review output minus its final VERDICT line — the findings the
    // rejection feedback forwards verbatim.
    private static func findingsText(from output: String) -> String {
        var lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let last = lines.last,
              last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.removeLast()
        }
        if let last = lines.last,
           last.trimmingCharacters(in: .whitespaces).hasPrefix("VERDICT:") {
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Sleep hold (§2.9 "Keep the Mac awake during runs")

    private func updateSleepHold() {
        var wanted = false
        if case .running = state, appDelegate?.autopilotPreventSleep == true { wanted = true }
        setSleepHold(wanted)
    }

    private func beginSleepHoldForSpawn() {
        if appDelegate?.autopilotPreventSleep == true { setSleepHold(true) }
    }

    private func setSleepHold(_ wanted: Bool) {
        if wanted, sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: .idleSystemSleepDisabled,
                reason: "Autopilot run in progress"
            )
        } else if !wanted, let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
    }

    // MARK: - Worker death (§2.7 watchdog)

    // Called by TerminalWindowController when the worker tab's shell exits
    // (it skips the clean-exit auto-close, so the scrollback survives).
    func workerTabExited(_ tab: Tab) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard tab.id == workerTabId else { return }
        guard case .running = state, let run = store.run else {
            workerTabId = nil
            return
        }
        guard AutopilotRunStage(rawValue: run.stage) == .working else {
            // The gates/merge/cleanup read git/gh, not the pty — a dead shell
            // there doesn't stop the pipeline (gate feedback discovers the
            // missing terminal itself). Leave the tab for inspection.
            store.log("worker tab's shell exited during \(run.stage) — tab left open")
            return
        }
        workerDied(reason: "the run tab's shell exited")
    }

    // One respawn with `claude --continue` + the resume prompt; a second
    // death blocks the phase. The dead tab stays open for debugging.
    private func workerDied(reason: String) {
        guard let run = store.run else { return }
        if respawnCount >= 1 {
            block(.workerDied,
                  "Phase \(run.phaseId): the worker died twice (\(reason)) — check the run tab",
                  phaseId: run.phaseId)
            return
        }
        respawnCount += 1
        store.log("worker died (\(reason)) — respawning once with --continue")
        // Un-pin so the session-ready watch re-arms; the old id stays in
        // sessionIds for the history row.
        store.updateRun { $0.sessionId = nil }
        guard openWorkerTab(run: run, continueSession: true) else {
            block(.workerDied,
                  "Phase \(run.phaseId): the worker died and no window could host the respawn",
                  phaseId: run.phaseId)
            return
        }
        postUpdate()
    }

    // MARK: - Worker-run helpers

    // Whether the engine owns this tab (the tabProcessDidExit intercept).
    func ownsTab(withId id: String) -> Bool {
        workerTabId == id
    }

    // The worker tab, resolved live across windows — tab ids stay valid
    // through drags/tear-offs, unlike weak content refs.
    private func workerTab() -> Tab? {
        guard let id = workerTabId,
              let (_, tab) = appDelegate?.controllerAndTab(withId: id) else { return nil }
        return tab
    }

    // The worker tab's terminal content — nil once the tab is gone OR its
    // shell exited (the tab is deliberately left open then, but a dead pty
    // swallows sends silently: LocalProcess.send guards on `running`, so
    // "delivered" feedback would be dropped while the log claims success).
    private func workerTerminal() -> TerminalPaneContent? {
        guard let tab = workerTab(), tab.exitStatus == nil else { return nil }
        return tab.content as? TerminalPaneContent
    }

    private func pinnedSession(_ run: AutopilotRun) -> ClaudeSession? {
        guard let id = run.sessionId else { return nil }
        return ClaudeSessionMonitor.shared.sessions.first { $0.id == id }
    }

    private static func processIsDead(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return true }
        return kill(pid, 0) != 0 && errno == ESRCH
    }

    // MARK: - Commands (palette / footer)

    // Bypasses the budget gate once. No-op while a run is active; a kept run
    // (after a block/pause) resumes through adoption rather than preflight —
    // preflight would only trip over its leftover worktree.
    func runNextPhaseNow() {
        guard let app = appDelegate, app.autopilotEnabled else {
            store.log("Run Next Phase Now ignored — Autopilot is disabled")
            return
        }
        if case .running = state {
            store.log("Run Next Phase Now ignored — a run is already active")
            return
        }
        if case .blocked = state {
            clearBlock()
        }
        if case .doneAllPhases = state {
            setState(.idle)
        }
        if case .paused = state {
            store.setPausedByUser(false)
            setState(.idle)
        }
        if store.run != nil {
            adoptPersistedRun(context: "run-next-phase-now")
            return
        }
        budgetBypassOnce = true
        lastPreflightAt = nil
        store.log("Run Next Phase Now — bypassing the budget gate once")
        tick()
    }

    // §2.9 palette Retry (shown while blocked): clears the block, then
    // either re-adopts the kept run at its true stage (§2.2) or re-runs
    // preflight right away.
    func retryAfterBlock() {
        guard case .blocked = state else { return }
        clearBlock()
        if store.run != nil {
            adoptPersistedRun(context: "retry")
            return
        }
        budgetBypassOnce = true
        lastPreflightAt = nil
        tick()
    }

    // §2.10 palette: an in-flight run always finishes; the engine parks
    // instead of starting the next one.
    func pauseAfterCurrentRun() {
        store.setPausedByUser(true)
        if case .running = state {
            store.log("pause requested — Autopilot pauses after the current run")
            postUpdate()
        } else {
            store.log("Autopilot paused")
            setState(.paused)
        }
    }

    func resume() {
        store.setPausedByUser(false)
        store.log("Autopilot resumed")
        guard case .paused = state else { return }
        // §2.9: resume = the adoption path — a kept run (e.g. after the user
        // closed the worker tab) is re-resolved and respawned, not
        // re-preflighted into its own leftover worktree.
        if store.run != nil {
            adoptPersistedRun(context: "resume")
        } else {
            setState(.idle)
        }
    }

    // §2.9 Skip Current Phase: append ⏸ to the phase heading in the MAIN
    // checkout's ROADMAP.md (the engine's one sanctioned write to the
    // steering file — steering stays in the file), interrupt the worker,
    // force-remove worktree + branch, record `skipped` in history, and let
    // the loop continue with the next phase.
    func skipCurrentPhase() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let app = appDelegate, app.autopilotEnabled else {
            store.log("Skip Current Phase ignored — Autopilot is disabled")
            return
        }
        guard let run = store.run else {
            store.log("Skip Current Phase: no phase run to skip — steer by editing ROADMAP.md")
            return
        }
        let root = app.autopilotProjectRoot
        // The ⏸ mark is load-bearing (without it the next preflight re-picks
        // the same phase), so it goes first and a failure aborts the skip.
        if let error = markPhaseSkipped(run.phaseId, root: root) {
            store.log("Skip Current Phase failed: \(error)")
            postUpdate()
            return
        }
        store.log("Phase \(run.phaseId) skipped — ⏸ appended to its ROADMAP.md heading")
        if let terminal = workerTerminal() {
            SessionControl.interrupt(terminal)
        }
        // An in-flight gate (build.sh / claude -p) still runs inside the
        // worktree that's about to be force-removed: kill it. Its completion
        // then fires promptly — dropped by the generation check — and
        // releases the in-flight flag, so the next phase isn't stalled
        // behind the abandoned gate's 15-minute watchdog.
        let gateHandle = activeGateHandle
        activeGateHandle = nil
        gateHandle?.cancel()
        store.appendHistory(CompletedRun(
            runId: run.id, phase: run.phaseId, title: run.title, slug: run.slug,
            branch: run.branch, startedAt: run.startedAt,
            endedAt: Date().timeIntervalSince1970,
            attempts: max(run.buildAttempts, run.reviewAttempts, 1),
            outcome: .skipped, prURL: nil, costUSD: run.costUSD,
            maxContextPct: run.maxContextPct, sessionIds: run.sessionIds,
            blockedReason: store.blocked?.reason
        ))
        closeWorkerTab()
        blockedMessage = nil
        store.setBlocked(nil)
        store.setRun(nil)
        resetRunMemory()
        // Force-remove the worktree + branch in the background. Failures are
        // only logged — but loudly, because the skipped slug is out of the
        // next preflight's leftover check, so an orphan won't be auto-cleaned.
        let worktreePath = run.worktreePath
        let branch = run.branch
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // Wait out the killed gate's death before removing its cwd —
            // removal must not race a process still writing into the tree.
            gateHandle?.waitUntilExited(timeout: 10)
            var warning: String?
            if FileManager.default.fileExists(atPath: worktreePath) {
                warning = WorktreeTasks.removeAfterRemoteMerge(worktreePath: worktreePath)
            } else {
                _ = WorktreeTasks.runGit(root, ["branch", "-D", branch])
                _ = WorktreeTasks.runGit(root, ["push", "origin", "--delete", branch])
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if let warning {
                    self.store.log("skip cleanup warning: \(warning) — remove \(worktreePath) manually")
                } else {
                    self.store.log("skipped phase's worktree and branch removed")
                }
            }
        }
        // lastPreflightAt is left standing (not reset): the ≥30 s pace gives
        // the background removal a head start so the next phase's preflight
        // never races the git operations above.
        setState(.idle)
    }

    // The one sanctioned Autopilot write to ROADMAP.md (§2.9). Returns an
    // error message, nil on success (including already-marked).
    private func markPhaseSkipped(_ phaseId: Int, root: String) -> String? {
        guard !root.isEmpty else { return "no Autopilot project is configured" }
        let path = root + "/ROADMAP.md"
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return "couldn't read \(path)"
        }
        guard let marked = RoadmapParser.markingPhaseSkipped(phaseId, in: content) else {
            return "Phase \(phaseId) has no heading in ROADMAP.md"
        }
        if marked == content { return nil } // already ⏸
        do {
            try marked.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            return "couldn't write \(path): \(error.localizedDescription)"
        }
        return nil
    }

    // Settings write-throughs poke this so mode/ceiling/root changes take
    // effect on the next decision instead of waiting out a throttle.
    func settingsChanged() {
        lastDecision = nil
        lastPreflightAt = nil
        updateSleepHold()
        tick()
    }

    // MARK: - Footer status (§2.11)

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    func footerStatus() -> AutopilotFooterStatus {
        switch state {
        case .off:
            return AutopilotFooterStatus(text: "Autopilot · off", tooltip: "Autopilot is disabled", kind: .idle)
        case .paused:
            return AutopilotFooterStatus(
                text: "Autopilot · paused",
                tooltip: "Paused by you — Run Next Phase Now resumes",
                kind: .paused
            )
        case .doneAllPhases:
            return AutopilotFooterStatus(
                text: "Autopilot · idle — no unshipped phases",
                tooltip: "Every ROADMAP.md phase is ✅ shipped or ⏸ skipped; editing the roadmap re-arms Autopilot",
                kind: .done
            )
        case .blocked(let reason):
            let message = blockedMessage ?? store.blocked?.message ?? reason.rawValue
            let text: String
            if let phaseId = store.blocked?.phaseId {
                text = "⚠ Phase \(phaseId) blocked — \(message)"
            } else {
                text = "⚠ Autopilot blocked — \(message)"
            }
            return AutopilotFooterStatus(text: text, tooltip: message, kind: .blocked)
        case .idle:
            if case .wait(let until, let why)? = lastDecision {
                let text: String
                if let until {
                    text = "Autopilot · next run ~" + Self.clockFormatter.string(from: until)
                } else {
                    text = "Autopilot · waiting"
                }
                return AutopilotFooterStatus(text: text, tooltip: why, kind: .idle)
            }
            return AutopilotFooterStatus(
                text: "Autopilot · idle",
                tooltip: "Waiting for the next scheduling decision",
                kind: .idle
            )
        case .running:
            guard let run = store.run else {
                return AutopilotFooterStatus(text: "⚙ Autopilot · running", tooltip: "", kind: .running)
            }
            let maxAttempts = appDelegate?.autopilotMaxGateAttempts ?? 3
            let prefix = "⚙ Phase \(run.phaseId)"
            let text: String
            switch AutopilotRunStage(rawValue: run.stage) {
            case .gatingBuild:
                let attempts = run.buildAttempts > 1 ? " (\(run.buildAttempts)/\(maxAttempts))" : ""
                text = "\(prefix) · gate: build\(attempts)"
            case .gatingReview:
                let attempts = run.reviewAttempts > 1 ? " (\(run.reviewAttempts)/\(maxAttempts))" : ""
                text = "\(prefix) · gate: review\(attempts)"
            case .merging:
                let pr = run.prNumber.map { " PR #\($0)" } ?? ""
                text = "\(prefix) · merging\(pr)"
            case .cleanup:
                text = "\(prefix) · cleaning up"
            case .working, nil:
                let minutes = max(0, Int(Date().timeIntervalSince1970 - run.startedAt) / 60)
                text = "\(prefix) · running \(minutes)m"
            }
            return AutopilotFooterStatus(
                text: text,
                tooltip: "Phase \(run.phaseId) — \(run.title)",
                kind: .running
            )
        }
    }

    // MARK: - Snapshot plumbing

    @objc private func sessionMonitorUpdated(_ note: Notification) {
        refreshSnapshot()
        guard case .running = state, let run = store.run else { return }
        if run.sessionId == nil {
            if AutopilotRunStage(rawValue: run.stage) == .working {
                tryPinWorkerSession(run)
            }
            return
        }
        guard let session = pinnedSession(run) else { return }
        // §2.10: cost/context sampled on every update, whatever the stage —
        // session files get pruned, the history row's data lives on the run.
        sampleSessionMetrics(session, run: run)
        guard AutopilotRunStage(rawValue: run.stage) == .working else { return }
        // The Stop hook flips the session to done at *every* turn end — that
        // only triggers verification (§2.7), world state decides.
        if session.state == .done {
            maybeStartVerification()
        }
    }

    private func refreshSnapshot() {
        guard let usage = ClaudeSessionMonitor.shared.readUsageSnapshot() else { return }
        let snapshot = UsageSnapshot(
            fiveHourPct: usage.fiveHourPct,
            sevenDayPct: usage.sevenDayPct,
            modelWeeklyMaxPct: usage.modelWeeklies.map(\.pct).max(),
            fiveHourResetsAt: usage.fiveHourResetsAt,
            sevenDayResetsAt: usage.sevenDayResetsAt,
            capturedAt: usage.capturedAt
        )
        guard snapshot != cachedSnapshot else { return }
        cachedSnapshot = snapshot
        // Mirror into state.json (relaunch shows "next run ~…"), but only when
        // something the scheduler reads changed — captured_at alone advances on
        // every statusline render and isn't worth a disk write.
        let stored = store.lastSnapshot
        if stored == nil
            || stored?.fiveHourPct != snapshot.fiveHourPct
            || stored?.sevenDayPct != snapshot.sevenDayPct
            || stored?.modelWeeklyMaxPct != snapshot.modelWeeklyMaxPct
            || stored?.fiveHourResetsAt != snapshot.fiveHourResetsAt?.timeIntervalSince1970
            || stored?.sevenDayResetsAt != snapshot.sevenDayResetsAt?.timeIntervalSince1970 {
            store.setLastSnapshot(AutopilotStore.Snapshot(
                fiveHourPct: snapshot.fiveHourPct,
                sevenDayPct: snapshot.sevenDayPct,
                modelWeeklyMaxPct: snapshot.modelWeeklyMaxPct,
                fiveHourResetsAt: snapshot.fiveHourResetsAt?.timeIntervalSince1970,
                sevenDayResetsAt: snapshot.sevenDayResetsAt?.timeIntervalSince1970,
                capturedAt: snapshot.capturedAt.timeIntervalSince1970
            ))
        }
    }

    private func seedSnapshotFromStore() {
        guard cachedSnapshot == nil, let stored = store.lastSnapshot else { return }
        cachedSnapshot = UsageSnapshot(
            fiveHourPct: stored.fiveHourPct,
            sevenDayPct: stored.sevenDayPct,
            modelWeeklyMaxPct: stored.modelWeeklyMaxPct,
            fiveHourResetsAt: stored.fiveHourResetsAt.map(Date.init(timeIntervalSince1970:)),
            sevenDayResetsAt: stored.sevenDayResetsAt.map(Date.init(timeIntervalSince1970:)),
            capturedAt: Date(timeIntervalSince1970: stored.capturedAt)
        )
    }

    private var schedulerConfig: AutopilotSchedulerConfig {
        guard let app = appDelegate else { return AutopilotSchedulerConfig() }
        return AutopilotSchedulerConfig(
            fiveHourCeiling: Double(app.autopilotFiveHourCeiling),
            weeklyCeiling: Double(app.autopilotWeeklyCeiling),
            weeklyHardStop: Double(app.autopilotWeeklyHardStop),
            paceTargetPct: Double(app.autopilotPaceTargetPct),
            nightStart: app.autopilotNightStart,
            nightEnd: app.autopilotNightEnd
        )
    }

    // MARK: - State plumbing

    private func setState(_ new: AutopilotEngineState) {
        guard state != new else { return }
        state = new
        generation += 1
        updateSleepHold()
        postUpdate()
    }

    private func block(_ reason: AutopilotBlockReason, _ message: String, phaseId: Int?) {
        blockedMessage = message
        store.setBlocked(AutopilotStore.Blocked(
            reason: reason.rawValue, message: message,
            at: Date().timeIntervalSince1970, phaseId: phaseId
        ))
        store.log("blocked (\(reason.rawValue)): \(message)")
        // §2.11: a block is always news — the attention center presents it
        // even while the app is frontmost.
        appDelegate?.postAutopilotNotification(
            title: phaseId.map { "Autopilot blocked — Phase \($0)" } ?? "Autopilot blocked",
            body: message, identifier: "autopilot-blocked"
        )
        setState(.blocked(reason))
    }

    private func clearBlock() {
        blockedMessage = nil
        store.setBlocked(nil)
        store.log("block cleared")
        setState(.idle)
    }

    // The state to land in when Autopilot turns (back) on — launch and the
    // re-enable path share it: persisted pause and block flags win (the run,
    // if any, is re-adopted by Resume/Retry), then a persisted run adopts
    // per §2.2, then plain idle.
    private func reactivateFromStore() {
        if store.pausedByUser {
            setState(.paused)
            return
        }
        if let blocked = store.blocked {
            blockedMessage = blocked.message
            setState(.blocked(AutopilotBlockReason(rawValue: blocked.reason) ?? .other))
            return
        }
        if store.run != nil {
            adoptPersistedRun(context: "adoption")
            return
        }
        setState(.idle)
    }

    private func describe(_ state: AutopilotEngineState) -> String {
        switch state {
        case .off: return "off"
        case .idle: return "idle"
        case .running: return "running"
        case .paused: return "paused"
        case .blocked(let reason): return "blocked (\(reason.rawValue))"
        case .doneAllPhases: return "done — no unshipped phases"
        }
    }

    private func postUpdate() {
        NotificationCenter.default.post(name: Self.didUpdate, object: self)
    }
}
