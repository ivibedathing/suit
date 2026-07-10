import Darwin
import Foundation

// Standalone model/state/config types for the Autopilot engine.
// Split out of AutopilotEngine.swift; see that file's header for
// the engine overview.

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
