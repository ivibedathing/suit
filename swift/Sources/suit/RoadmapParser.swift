import Foundation

// ROADMAP.md as an interface (ROADMAP Phase 32): Autopilot steers itself by
// re-reading the roadmap at every scheduling decision. Priority is document
// order; a ✅ anywhere in a phase heading means shipped (which covers the
// "✅ shipped (note)" parenthetical variants), a ⏸ anywhere means skipped,
// and the first phase that is neither is the next unit of work. Pure string
// parsing with no app dependencies, so it compiles standalone for the
// scratch logic tests (the Phase 16/22 convention).

// One `### Phase N — Title` section of the roadmap.
struct RoadmapPhase {
    let number: Int
    let title: String   // heading title with any trailing ✅/⏸ marker stripped
    let heading: String // the full "### Phase N — …" line, verbatim
    let body: String    // spec text below the heading, up to the next ##/### heading
    let shipped: Bool   // ✅ anywhere in the heading
    let skipped: Bool   // ⏸ anywhere in the heading

    // Worktree/branch identity: "phase-<n>-<title>" slugified. The engine
    // hands this to WorktreeTasks.createTask as the task name, so the
    // worktree lands at .claude/worktrees/<slug> on branch task/<slug>.
    var slug: String { RoadmapParser.slug(from: "phase-\(number)-\(title)") }
    var branch: String { "task/" + slug }

    // What the worker prompt embeds verbatim (snapshotted at spawn) and the
    // review gate later judges against: heading line plus the full body.
    var specText: String { body.isEmpty ? heading : heading + "\n\n" + body }
}

enum RoadmapParser {
    // Every well-formed phase section, in document order. A heading must
    // match ^### Phase (\d+) — (.+)$ exactly (ASCII digits, spaced em dash,
    // non-empty title); malformed variants are not phases, though as ##/###
    // lines they still terminate the preceding phase's body.
    static func phases(in markdown: String) -> [RoadmapPhase] {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        var phases: [RoadmapPhase] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            guard let (number, rawTitle) = matchHeading(line) else { continue }
            var bodyLines: [Substring] = []
            while index < lines.count, !lines[index].hasPrefix("##") {
                bodyLines.append(lines[index])
                index += 1
            }
            while let first = bodyLines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
                bodyLines.removeFirst()
            }
            while let last = bodyLines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                bodyLines.removeLast()
            }
            phases.append(RoadmapPhase(
                number: number,
                title: cleanTitle(rawTitle),
                heading: String(line),
                body: bodyLines.joined(separator: "\n"),
                shipped: containsMarker(line, shippedScalar),
                skipped: containsMarker(line, skippedScalar)))
        }
        return phases
    }

    // The next phase Autopilot should work: first in document order that is
    // neither shipped nor skipped. nil = every phase is done (doneAllPhases).
    static func eligiblePhase(in markdown: String) -> RoadmapPhase? {
        phases(in: markdown).first { !$0.shipped && !$0.skipped }
    }

    static func phase(numbered number: Int, in markdown: String) -> RoadmapPhase? {
        phases(in: markdown).first { $0.number == number }
    }

    // Same character rules as WorktreeTasks.slug (keep in sync), plus a
    // trailing-dash trim after the 48-char cut so the result is a fixed
    // point of that function — createTask re-slugs the name it is given,
    // and the branch/directory it makes must match RoadmapPhase.slug.
    static func slug(from name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let mapped = name.lowercased().map { char -> Character in
            char.unicodeScalars.allSatisfy { allowed.contains($0) } ? char : "-"
        }
        let collapsed = String(mapped).split(separator: "-").joined(separator: "-")
        var result = String(collapsed.prefix(48))
        while result.hasSuffix("-") { result.removeLast() }
        return result
    }

    // MARK: - Internals

    private static let shippedScalar: Unicode.Scalar = "\u{2705}" // ✅
    private static let skippedScalar: Unicode.Scalar = "\u{23F8}" // ⏸

    // Scalar-level scan so "⏸️" (with a variation selector) still counts.
    private static func containsMarker(_ line: Substring, _ scalar: Unicode.Scalar) -> Bool {
        line.unicodeScalars.contains(scalar)
    }

    // ^### Phase (\d+) — (.+)$ → (number, raw title), nil when malformed.
    private static func matchHeading(_ line: Substring) -> (Int, Substring)? {
        let prefix = "### Phase "
        guard line.hasPrefix(prefix) else { return nil }
        var rest = line.dropFirst(prefix.count)
        var digits = ""
        while let char = rest.first, char.isASCII, char.isNumber {
            digits.append(char)
            rest = rest.dropFirst()
        }
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        let separator = " \u{2014} " // spaced em dash
        guard rest.hasPrefix(separator) else { return nil }
        let title = rest.dropFirst(separator.count)
        guard !title.isEmpty else { return nil }
        return (number, title)
    }

    // "Search — ✅ shipped (note)" → "Search": cut at the first status
    // marker, then drop the dangling separator dash it usually rides on.
    private static func cleanTitle(_ raw: Substring) -> String {
        var scalars = raw.unicodeScalars
        if let cut = scalars.firstIndex(where: { $0 == shippedScalar || $0 == skippedScalar }) {
            scalars = scalars[..<cut]
        }
        var title = String(scalars).trimmingCharacters(in: .whitespaces)
        if title.hasSuffix("\u{2014}") || title.hasSuffix("-") {
            title = String(title.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return title
    }
}
