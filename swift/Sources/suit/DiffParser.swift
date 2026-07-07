import Foundation

// Unified-diff parsing (ROADMAP Phase 3), separate from the pane UI so it can
// be reused (Phase 5 review sets) and tested standalone.
struct DiffLine {
    enum Kind {
        case fileHeader   // diff --git a/… b/…
        case hunkHeader   // @@ -l,c +l,c @@
        case context
        case addition
        case deletion
        case meta         // index/---/+++/mode lines
    }

    let kind: Kind
    let text: String
    let oldLine: Int?
    let newLine: Int?
}

enum UnifiedDiffParser {
    static func parse(_ diff: String) -> [DiffLine] {
        var lines: [DiffLine] = []
        var oldLine = 0
        var newLine = 0

        diff.enumerateLines { raw, _ in
            if raw.hasPrefix("diff --git ") {
                lines.append(DiffLine(kind: .fileHeader, text: raw, oldLine: nil, newLine: nil))
                return
            }
            if raw.hasPrefix("@@") {
                // @@ -oldStart[,count] +newStart[,count] @@ …
                let parts = raw.split(separator: " ")
                if parts.count >= 3,
                   let old = Int(parts[1].dropFirst().split(separator: ",").first ?? ""),
                   let new = Int(parts[2].dropFirst().split(separator: ",").first ?? "") {
                    oldLine = old
                    newLine = new
                }
                lines.append(DiffLine(kind: .hunkHeader, text: raw, oldLine: nil, newLine: nil))
                return
            }
            if raw.hasPrefix("+++") || raw.hasPrefix("---") || raw.hasPrefix("index ")
                || raw.hasPrefix("new file") || raw.hasPrefix("deleted file")
                || raw.hasPrefix("old mode") || raw.hasPrefix("new mode")
                || raw.hasPrefix("similarity") || raw.hasPrefix("rename")
                || raw.hasPrefix("Binary files") || raw.hasPrefix("\\ No newline") {
                lines.append(DiffLine(kind: .meta, text: raw, oldLine: nil, newLine: nil))
                return
            }
            if raw.hasPrefix("+") {
                lines.append(DiffLine(kind: .addition, text: String(raw.dropFirst()), oldLine: nil, newLine: newLine))
                newLine += 1
                return
            }
            if raw.hasPrefix("-") {
                lines.append(DiffLine(kind: .deletion, text: String(raw.dropFirst()), oldLine: oldLine, newLine: nil))
                oldLine += 1
                return
            }
            // Context (leading space, or empty context line).
            let text = raw.hasPrefix(" ") ? String(raw.dropFirst()) : raw
            lines.append(DiffLine(kind: .context, text: text, oldLine: oldLine, newLine: newLine))
            oldLine += 1
            newLine += 1
        }
        return lines
    }

    // The changed file paths in a diff (b/ side), for review-set walking.
    static func changedPaths(_ diff: String) -> [String] {
        var paths: [String] = []
        diff.enumerateLines { raw, _ in
            guard raw.hasPrefix("diff --git a/") else { return }
            // "diff --git a/x b/x" — take the b/ path, which survives renames.
            if let range = raw.range(of: " b/") {
                paths.append(String(raw[range.upperBound...]))
            }
        }
        return paths
    }
}

