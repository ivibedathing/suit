import Foundation

// Claude Code permission-mode control (ROADMAP Phase 26). Claude Code's Plan /
// auto-accept / normal modes hide behind Shift+Tab cycling; Suit surfaces them
// as a visible Ask · Plan · Agent segmented control on a Claude tab's title bar
// and drives them the only way a control surface can — by writing the Shift+Tab
// key sequence into the pane's pty. Purely a control surface: no Claude-side
// changes, and the "current mode" is best-effort (readback from the session
// JSON when Claude ever exposes it, else the last mode Suit itself sent).

enum ClaudeMode: String, CaseIterable {
    // Ask — Claude's "default" permission mode: it asks before each edit/run.
    case ask
    // Plan — read-only planning; Claude maps the code and proposes a plan
    // before touching a file (the mode this whole phase is built around).
    case plan
    // Agent — "acceptEdits": Claude runs agentically, auto-accepting edits.
    case agent

    // The label on the segmented control.
    var label: String {
        switch self {
        case .ask: return "Ask"
        case .plan: return "Plan"
        case .agent: return "Agent"
        }
    }

    // Position in Claude Code's Shift+Tab cycle: default → acceptEdits → plan →
    // (wraps). This is the order a Shift+Tab press advances through, so the
    // number of presses to reach a target is a modular subtraction over these
    // indices — NOT the Ask · Plan · Agent display order.
    var cycleIndex: Int {
        switch self {
        case .ask: return 0     // default
        case .agent: return 1   // acceptEdits
        case .plan: return 2    // plan
        }
    }

    // The order the segmented control renders left→right (the roadmap's
    // Ask · Plan · Agent), distinct from the Shift+Tab cycle order above.
    static let displayOrder: [ClaudeMode] = [.ask, .plan, .agent]

    // Best-effort readback: the raw permission-mode string the session JSON
    // might carry (Claude Code's internal identifiers), mapped onto our three
    // buckets. bypassPermissions collapses onto Agent — same "just run it"
    // posture from the control's point of view. nil for anything unrecognized.
    static func fromRawMode(_ raw: String?) -> ClaudeMode? {
        switch raw {
        case "plan": return .plan
        case "acceptEdits", "bypassPermissions", "agent": return .agent
        case "default", "ask": return .ask
        default: return nil
        }
    }
}

// The Shift+Tab escape sequence a terminal sends (CSI Z, "back-tab"), which
// Claude Code's TUI reads as its mode-cycle key.
enum ClaudeModeControl {
    static let shiftTab = "\u{1b}[Z"

    // How many Shift+Tab presses advance the cycle from `current` to `target`
    // (0 when already there). Pure and total — a modular step over cycleIndex.
    static func presses(from current: ClaudeMode, to target: ClaudeMode) -> Int {
        ((target.cycleIndex - current.cycleIndex) % 3 + 3) % 3
    }

    // The exact bytes written into the pty to move from `current` to `target`:
    // the Shift+Tab sequence repeated `presses(...)` times ("" when no change).
    // This is what the mode-switch verification asserts on.
    static func payload(from current: ClaudeMode, to target: ClaudeMode) -> String {
        String(repeating: shiftTab, count: presses(from: current, to: target))
    }
}

// Per-session memory of the last mode Suit sent, so the control can reflect a
// believed state and the next switch cycles the right number of steps. Keyed
// by session id; a session that's never been steered has no entry and the
// control falls back to Agent (Suit's quick-launchers run Claude agentically).
final class ClaudeModeTracker {
    static let shared = ClaudeModeTracker()

    private var lastSent: [String: ClaudeMode] = [:]

    func record(_ mode: ClaudeMode, forSessionId id: String) {
        lastSent[id] = mode
    }

    func lastSent(forSessionId id: String) -> ClaudeMode? {
        lastSent[id]
    }

    // The mode the control should show for a session: an explicit readback from
    // the session JSON wins; otherwise the last mode Suit sent; otherwise Agent.
    func effectiveMode(for session: ClaudeSession) -> ClaudeMode {
        session.permissionMode ?? lastSent[session.id] ?? .agent
    }
}
