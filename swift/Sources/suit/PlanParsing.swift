import Foundation

// Plan-approval parsing. When a Claude session in Plan mode
// finishes planning, it calls the ExitPlanMode tool with the proposed plan as
// markdown. That tool_use in the session's JSONL transcript is the reliable
// signal a plan has arrived — far more robust than scraping rendered text — so
// the plan-approval pane extracts the latest one and splits it into steps.
//
// UI-free and pure so the "renders every step in order" verification can assert
// against it directly.

struct ClaudePlan: Equatable {
    // The plan's raw markdown, as Claude wrote it (shown verbatim below the
    // numbered steps so nothing is lost in the splitting).
    let rawMarkdown: String
    // The plan broken into ordered steps — list items where the plan uses a
    // list, else its non-empty prose lines.
    let steps: [String]
}

enum PlanParser {
    // The latest plan in a transcript file, or nil when the file has no
    // ExitPlanMode tool call (no plan awaiting approval).
    static func latestPlan(inTranscriptAt path: String) -> ClaudePlan? {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return latestPlan(inTranscriptLines: contents.components(separatedBy: "\n"))
    }

    static func latestPlan(inTranscriptLines lines: [String]) -> ClaudePlan? {
        guard let markdown = latestPlanMarkdown(inTranscriptLines: lines) else { return nil }
        return ClaudePlan(rawMarkdown: markdown, steps: steps(fromMarkdown: markdown))
    }

    // Scans every JSONL line and keeps the last assistant ExitPlanMode tool_use's
    // `plan` input — a session can plan more than once, and the freshest plan is
    // the one the user is being asked to approve.
    static func latestPlanMarkdown(inTranscriptLines lines: [String]) -> String? {
        var latest: String?
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (object["type"] as? String) == "assistant",
                  let message = object["message"] as? [String: Any] else { continue }
            for case let block as [String: Any] in message["content"] as? [Any] ?? [] {
                guard (block["type"] as? String) == "tool_use" else { continue }
                let name = (block["name"] as? String) ?? ""
                // Accept the studlycaps tool name and a snake_case variant, in
                // case the transcript schema ever shifts.
                guard name == "ExitPlanMode" || name == "exit_plan_mode" else { continue }
                if let plan = (block["input"] as? [String: Any])?["plan"] as? String,
                   !plan.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    latest = plan
                }
            }
        }
        return latest
    }

    // Splits plan markdown into ordered steps: strip list markers (-, *, +, or
    // "N." / "N)") from list lines and keep them; if the plan is prose with no
    // list, fall back to its non-empty, non-heading lines so there is still
    // something to render as numbered steps.
    static func steps(fromMarkdown markdown: String) -> [String] {
        var listItems: [String] = []
        var proseLines: [String] = []
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let item = strippedListItem(line) {
                listItems.append(item)
            } else if !line.hasPrefix("#") {
                proseLines.append(line)
            }
        }
        return listItems.isEmpty ? proseLines : listItems
    }

    // The text of a bullet or numbered list item, or nil if the line isn't one.
    private static func strippedListItem(_ line: String) -> String? {
        if let first = line.first, first == "-" || first == "*" || first == "+" {
            let rest = line.dropFirst()
            if rest.first == " " {
                return rest.drop(while: { $0 == " " }).isEmpty ? nil : String(rest.dropFirst())
            }
            return nil
        }
        // "12. text" / "3) text"
        var digits = ""
        var index = line.startIndex
        while index < line.endIndex, line[index].isNumber {
            digits.append(line[index])
            index = line.index(after: index)
        }
        guard !digits.isEmpty, index < line.endIndex, line[index] == "." || line[index] == ")" else { return nil }
        let after = line[line.index(after: index)...]
        guard after.first == " " else { return nil }
        let text = after.drop(while: { $0 == " " })
        return text.isEmpty ? nil : String(text)
    }
}

// The three actions on the plan-approval pane, mapped onto
// the numbered options of Claude Code's ExitPlanMode approval menu:
//
//   Would you like to proceed?
//   ❯ 1. Yes, and auto-accept edits
//     2. Yes, and manually approve edits
//     3. No, keep planning
//
// so each button injects the exact hotkey that selects its option (submitted
// with a return). Pure so the "inject the correct payload" verification can
// assert the strings without a running session.
enum PlanApprovalAction: CaseIterable {
    case approveAndRun    // 1 — proceed, auto-accept edits
    case edit             // 2 — proceed, but manually approve/edit each change
    case discard          // 3 — no, keep planning (the plan isn't run)

    var buttonTitle: String {
        switch self {
        case .approveAndRun: return "Approve & Run"
        case .edit: return "Edit"
        case .discard: return "Discard"
        }
    }

    // The pty text sent (via SessionControl.send, so a return follows).
    var ptyPayload: String {
        switch self {
        case .approveAndRun: return "1"
        case .edit: return "2"
        case .discard: return "3"
        }
    }
}
