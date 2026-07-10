import Foundation

// Broadcast input to multiple sessions. Fan a single
// instruction across many Claude panes at once (the iTerm "send to all
// sessions" gesture), made deliberate rather than silent. Where `SessionControl.send`
// pipes text into one session, this loops that same call over a resolved
// set of targets.
//
// The pure decision logic lives here — Foundation-only, no AppKit — so the
// target resolution and confirm rule are verifiable without a running app,
// matching the RoadmapParser/FeedbackRouting/DiffReview standalone-test pattern.
// The composer (PromptComposer.swift) is the UI that composes once and, on
// send, loops over the resolved terminals.
enum Broadcast {
    // Which sessions a broadcast aims at.
    enum Scope: Equatable {
        case allLive                 // every steerable live session
        case selected(Set<String>)   // the fleet rows the user checked
    }

    // The ordered, deduped session ids a broadcast will actually reach. Only
    // sessions whose pty is hosted by some pane are steerable (an unhosted
    // "done" file can't be written to), and the order follows the fleet's
    // needs-you-first ordering that `orderedSessionIds` carries, so the
    // composer's "N sessions" and the send agree. `selected` intersects with
    // the hosted set — a checked row whose tab has since closed silently drops
    // rather than erroring.
    static func targetIds(
        orderedSessionIds: [String],
        hostedIds: Set<String>,
        scope: Scope
    ) -> [String] {
        var seen = Set<String>()
        return orderedSessionIds.filter { id in
            guard hostedIds.contains(id), !seen.contains(id) else { return false }
            switch scope {
            case .allLive:
                seen.insert(id)
                return true
            case .selected(let selection):
                guard selection.contains(id) else { return false }
                seen.insert(id)
                return true
            }
        }
    }

    // Broadcasting is a bulk fan-out; a stray line landing in several agents'
    // input boxes at once is worth one beat of confirmation. A single target
    // sends without ceremony — it's just the ordinary composer aimed elsewhere.
    static func needsConfirmation(targetCount: Int, multiTargetThreshold: Int = 2) -> Bool {
        targetCount >= multiTargetThreshold
    }

    // "N sessions" / "1 session", the shared count phrasing for the composer
    // label and the confirm dialog.
    static func sessionCountLabel(_ count: Int) -> String {
        "\(count) session\(count == 1 ? "" : "s")"
    }

    static func confirmMessage(targetCount: Int) -> String {
        "Send this to \(sessionCountLabel(targetCount)) at once?"
    }
}
