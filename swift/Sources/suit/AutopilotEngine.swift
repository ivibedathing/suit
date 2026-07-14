import Darwin
import Foundation

// The Autopilot engine: the main-queue state machine that
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
//
// This file holds the primary type declaration, all stored properties and
// `init`; the method clusters live in AutopilotEngine+*.swift extensions and
// the standalone model/state types in AutopilotEngineTypes.swift.

// NSObject for the selector-based NotificationCenter observation below.
final class AutopilotEngine: NSObject {
    static let didUpdate = Notification.Name("AutopilotEngineDidUpdate")

    // The git repo (containing ROADMAP.md) this engine drives. Each concurrent
    // autopilot owns one root; AutopilotManager keys instances by it. Replaces
    // the old single app-wide autopilotProjectRoot lookup.
    let projectRoot: String

    // Set once by AutopilotManager; the engine reads its §2.9 settings (mode,
    // ceilings, stall minutes, …) through it live. The project root is now the
    // engine's own `projectRoot`, not read from here.
    weak var appDelegate: AppDelegate?

    var state: AutopilotEngineState = .off
    // Bumped on every state transition; background completions capture it at
    // launch and drop themselves when it moved on (§2.1).
    var generation = 0

    // Whether the footer row shows at all — hidden while the setting is off.
    var isActive: Bool {
        if case .off = state { return false }
        return true
    }

    // Holding the single active-run slot: a live run (any stage), an in-flight
    // adoption resolving into one, or a background job already claiming the
    // slot — crucially the idle→preflight→spawn window, where `state` is still
    // `.idle` but `inFlight` is set, so a sibling ticking later in the same
    // manager pass can't also start. The manager's one-at-a-time gate keys on
    // this.
    var isOccupyingRunSlot: Bool {
        if adopting || inFlight { return true }
        if case .running = state { return true }
        return false
    }

    // The repo's folder name — the dashboard/footer label for this instance.
    var displayName: String {
        let trimmed = projectRoot.hasSuffix("/") ? String(projectRoot.dropLast()) : projectRoot
        let last = (trimmed as NSString).lastPathComponent
        return last.isEmpty ? projectRoot : last
    }

    let store: AutopilotStore

    // MARK: - Tick throttles (§2.4 last paragraph)

    // The one flag preventing overlapping background work (preflight,
    // verification, gates, merge, cleanup, adoption). Token-owned: every job
    // takes a fresh token at start, and a completion releases the flag only
    // while it still holds the newest one — a stale callback (about to be
    // dropped by the generation check anyway) must never free a hold a newer
    // job acquired after it, e.g. a mid-verification block → palette Retry →
    // adoption, whose gh lookup would otherwise race a second verification.
    var inFlight = false
    var backgroundJobToken = 0

    func beginBackgroundJob() -> Int {
        inFlight = true
        backgroundJobToken += 1
        return backgroundJobToken
    }

    func endBackgroundJob(_ token: Int) {
        if token == backgroundJobToken { inFlight = false }
    }

    // §2.2 adoption in flight: the persisted run's true stage is still being
    // resolved against GitHub, so the per-tick stage dispatcher must not
    // drive the (possibly stale) persisted stage meanwhile.
    var adopting = false
    // git/gh polls ≥30 s apart, scoped per stage; idle's poll is preflight.
    static let gitPollInterval: TimeInterval = 30
    var lastPreflightAt: Date?
    // ROADMAP.md mtime stat ~every 10 s (doneAllPhases auto-recovery).
    static let roadmapCheckInterval: TimeInterval = 10
    var lastRoadmapCheckAt: Date?
    var roadmapMtimeAtDone: Date?

    // "Run Next Phase Now": bypass the budget gate for the next tick only.
    var budgetBypassOnce = false

    // MARK: - Worker-run plumbing (§2.5–§2.7)

    // The worker tab. A per-launch UUID — never persisted (§2.10); relaunch
    // adoption re-resolves or respawns. Exposed for AppDelegate's
    // focusAutopilotRunTab and the tabProcessDidExit intercept.
    var workerTabId: String?
    // §2.5: no matching session file within 20 s of the launch → blocked
    // (covers the one-time --dangerously-skip-permissions acceptance dialog).
    static let sessionReadyTimeout: TimeInterval = 20
    var sessionReadyDeadline: Date?
    // The next session-ready delivery sends the resume prompt (post-respawn)
    // instead of the full worker instructions.
    var deliverResumePrompt = false
    // Gate feedback that couldn't reach a live session (the shell died during
    // the gates, or an adopted run never had a tab): delivered on the next
    // session-ready in place of the resume prompt — `--continue` restores the
    // conversation, so the feedback itself is the resume.
    var pendingFeedbackMessage: String?
    // §2.7 watchdogs: one respawn with --continue per run, a second death
    // blocks; each attempt gets its own 90-min wall clock.
    var respawnCount = 0
    var attemptStartedAt: Date?
    static let wallClockCap: TimeInterval = 90 * 60
    static let frozenSessionAge: TimeInterval = 30 * 60
    // §2.7 completion verification: session `done` only triggers it, world
    // state decides; throttled ≥30 s like the other git/gh polls.
    static let verificationInterval: TimeInterval = 30
    var lastVerificationAt: Date?
    static let maxNudges = 5
    static let nudgeSpacing: TimeInterval = 2 * 60
    // §2.9 needs-input stall: one best-judgment nudge at ~10 min, blocked
    // past autopilotStallMinutes.
    static let stallNudgeAfter: TimeInterval = 10 * 60
    var needsInputSince: Date?
    var stallNudgeSent = false

    // MARK: - Gate + merge memory (§2.8; in-memory, reset at spawn/cleanup)

    // A broken review gate (timeout / unparseable verdict / failed diff) gets
    // exactly one retry, then a global block — never an auto-approve.
    var reviewGateBrokenCount = 0
    // The running gate's process handle (build.sh / claude -p), so Skip
    // Current Phase can kill it before force-removing the worktree it runs in.
    var activeGateHandle: AutopilotGateHandle?
    // `gh pr merge` succeeded but the PR hasn't read MERGED yet (merge queue):
    // subsequent merge-stage ticks only re-poll prState, never re-merge.
    var mergeConfirmedPending = false
    // Merge-stage polls (retries + MERGED confirmation) share the ≥30 s pace.
    var lastMergePollAt: Date?
    // §2.8 step 3: "not mergeable" conflict feedback rounds are capped at 2.
    static let mergeConflictCap = 2
    // §2.9 "Keep the Mac awake during runs": held across spawning…cleanup.
    var sleepActivity: NSObjectProtocol?

    // The cached usage snapshot the budget math runs on every tick — refreshed
    // when ClaudeSessionMonitor reloads (file events + the 30 s heartbeat),
    // seeded from state.json on launch so a relaunch can still show
    // "next run ~03:40" before fresh usage arrives.
    var cachedSnapshot: UsageSnapshot?
    var lastDecision: AutopilotScheduleDecision?

    // The human line behind the current block, for the footer tooltip.
    var blockedMessage: String?

    // Repaint trigger: didUpdate is posted whenever the composed footer text
    // changes (elapsed-minutes drift included), not on every tick.
    var lastStatusText = ""

    // §2.11 footer clock — the "next run ~HH:mm" formatter.
    static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    init(projectRoot: String) {
        self.projectRoot = projectRoot
        self.store = AutopilotStore(projectRoot: projectRoot)
        super.init()
        // Observing by name doesn't instantiate the monitor — safe even though
        // an engine can be created early (the sidebar footer / launch adoption).
        NotificationCenter.default.addObserver(
            self, selector: #selector(sessionMonitorUpdated(_:)),
            name: ClaudeSessionMonitor.didUpdate, object: nil
        )
    }
}
