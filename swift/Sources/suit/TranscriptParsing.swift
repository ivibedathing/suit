import Foundation

// MARK: - Transcript parsing

// One rendered item of the conversation. Tool calls collapse to a single
// summary line; thinking blocks, sidechain (subagent) traffic, and transcript
// bookkeeping entries (mode, file-history-snapshot, attachment, …) are
// dropped entirely.
enum TranscriptEntry: Equatable {
    case user(String)
    case assistantText(String)
    case toolUse(name: String, summary: String)

    // The searchable / snippet text of an entry, independent of its rendered
    // decoration (used by cross-transcript search and the pane's
    // jump anchoring).
    var plainText: String {
        switch self {
        case .user(let text): return text
        case .assistantText(let text): return text
        case .toolUse(let name, let summary): return summary.isEmpty ? name : "\(name) — \(summary)"
        }
    }
}

// A single JSONL line can carry several content blocks (one assistant message
// interleaves text and tool_use), so parsing returns zero or more entries.
// Free function so it's testable without a pane.
func parseTranscriptLine(_ line: String) -> [TranscriptEntry] {
    guard let data = line.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let type = object["type"] as? String else { return [] }
    // Subagent conversations share the file but aren't this session's thread.
    if object["isSidechain"] as? Bool == true { return [] }
    guard type == "user" || type == "assistant",
          let message = object["message"] as? [String: Any] else { return [] }

    if type == "user" {
        // Real prompts are plain strings; array content is tool_result plumbing.
        // Skip slash-command wrappers (<command-name>…) and other tag-shaped
        // synthetic prompts.
        guard let text = message["content"] as? String else { return [] }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<") else { return [] }
        return [.user(trimmed)]
    }

    var entries: [TranscriptEntry] = []
    for case let block as [String: Any] in message["content"] as? [Any] ?? [] {
        switch block["type"] as? String {
        case "text":
            if let text = (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                entries.append(.assistantText(text))
            }
        case "tool_use":
            let name = block["name"] as? String ?? "tool"
            entries.append(.toolUse(name: name, summary: toolSummary(input: block["input"] as? [String: Any])))
        default:
            break // thinking, images, …
        }
    }
    return entries
}

// The one input field worth showing for a collapsed tool call, by usefulness:
// a path beats a command beats a free-text description.
private func toolSummary(input: [String: Any]?) -> String {
    guard let input else { return "" }
    for key in ["file_path", "path", "command", "pattern", "query", "prompt", "description", "skill", "name", "url"] {
        if let value = input[key] as? String, !value.isEmpty {
            let flat = value.replacingOccurrences(of: "\n", with: " ")
            return flat.count > 120 ? String(flat.prefix(120)) + "…" : flat
        }
    }
    return ""
}

// Same resolution rules as the terminal's Cmd-click links (PaneTerminalView.
// resolveFileLink), but against an explicit base directory since a transcript
// pane has no shell: strip a trailing :line[:col], try absolute then
// cwd-relative, and only accept paths that exist as regular files.
func resolveFileReference(_ link: String, relativeTo cwd: String?) -> (path: String, line: Int?)? {
    guard !link.contains("://"), !link.hasPrefix("mailto:") else { return nil }

    var parts = link.components(separatedBy: ":")
    var numbers: [Int] = []
    while parts.count > 1, numbers.count < 2, let n = Int(parts.last ?? ""), n > 0 {
        numbers.insert(n, at: 0)
        parts.removeLast()
    }
    let line = numbers.first

    for (candidate, candidateLine) in [(parts.joined(separator: ":"), line), (link, nil)] {
        let expanded = (candidate as NSString).expandingTildeInPath
        let absolute: String
        if expanded.hasPrefix("/") {
            absolute = expanded
        } else if let cwd {
            absolute = cwd + "/" + expanded
        } else {
            continue
        }
        let standardized = (absolute as NSString).standardizingPath
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: standardized, isDirectory: &isDirectory), !isDirectory.boolValue {
            return (standardized, candidateLine)
        }
    }
    return nil
}
