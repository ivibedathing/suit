import Foundation

// "Set as Goal" text composition (ROADMAP Phase 18), separated from AppDelegate
// so it is pure and standalone-compilable — the AutopilotScheduler /
// RoadmapParser convention, verified by scripts/goal-harness.sh without pulling
// in AppKit. `composeGoalText` builds the `/goal `-prefixed payload sent into a
// chosen Claude session; `bracketedPaste` mirrors SessionControl.send's Phase 8
// framing so a multi-line selection stays one input-box unit.
enum GoalComposition {
    // The `/goal `-prefixed text sent into a session's pty. Returns nil for an
    // all-whitespace selection (nothing to steer with — the caller beeps and
    // the menu item is disabled at the selection level anyway). When provenance
    // is on and a source location is known, a `From <file>:<lines>:` line is
    // prepended: a single `start` for one-line selections, `start-end` for a
    // span.
    static func composeGoalText(selection: String, file: String?, startLine: Int?, endLine: Int?, includeProvenance: Bool) -> String? {
        let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var payload = trimmed
        if includeProvenance, let file, let startLine {
            let name = (file as NSString).lastPathComponent
            let range = (endLine.map { $0 != startLine } ?? false) ? "\(startLine)-\(endLine!)" : "\(startLine)"
            payload = "From \(name):\(range):\n" + trimmed
        }
        return "/goal " + payload
    }

    // The bracketed-paste framing SessionControl.send wraps a payload in, so a
    // multi-line goal arrives at the TUI as one paste (embedded newlines stay
    // literal input-box newlines instead of submitting at the first \n).
    // Mirrors that send path's markers so the harness can assert a composed
    // goal reaches the pty as exactly one bracketed-paste unit.
    static let pasteStart = "\u{1b}[200~"
    static let pasteEnd = "\u{1b}[201~"

    static func bracketedPaste(_ text: String) -> String {
        pasteStart + text + pasteEnd
    }
}
