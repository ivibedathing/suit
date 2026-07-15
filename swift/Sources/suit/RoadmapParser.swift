import Foundation

// ROADMAP.md as an interface: Autopilot steers itself by
// re-reading the roadmap at every scheduling decision. Priority is document
// order; a ✅ anywhere in a phase heading means shipped (which covers the
// "✅ shipped (note)" parenthetical variants), a ⏸ anywhere means skipped,
// and the first phase that is neither is the next unit of work. Pure string
// parsing with no app dependencies, so it compiles standalone for the
// scratch logic tests (the scratch-logic-test convention).

// One `### Phase N — Title` section of the roadmap.
struct RoadmapPhase {
    let number: Int
    let title: String   // heading title with any trailing ✅/⏸ marker stripped
    let heading: String // the full "### Phase N — …" line, verbatim
    let body: String    // spec text below the heading, up to the next ##/### heading
    let shipped: Bool   // ✅ anywhere in the heading
    let skipped: Bool   // ⏸ anywhere in the heading
    // Optional per-phase routing annotations (token-cost routing): a body
    // line of the form "model: haiku" / "effort: low" (optionally "- "-led,
    // case-insensitive key, value verbatim, first occurrence wins) routes
    // this phase's worker onto a cheaper model / effort tier via
    // ANTHROPIC_MODEL / CLAUDE_CODE_EFFORT_LEVEL. nil = session default.
    let model: String?
    let effort: String?

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
    // The roadmap's one canonical location: <root>/ROADMAP.md. Call sites
    // never rebuild the path by hand, so the filename can't drift.
    static func path(inRoot root: String) -> String {
        root + "/ROADMAP.md"
    }

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
            let body = bodyLines.joined(separator: "\n")
            phases.append(RoadmapPhase(
                number: number,
                title: cleanTitle(rawTitle),
                heading: String(line),
                body: body,
                shipped: containsMarker(line, shippedScalar),
                skipped: containsMarker(line, skippedScalar),
                model: annotation("model", in: body),
                effort: annotation("effort", in: body)))
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

    // The markdown with " — ⏸ skipped" appended to phase N's heading — the
    // text transform behind Autopilot's Skip Current Phase, its one
    // sanctioned write to the steering file (§2.9). Pure so it's testable
    // standalone. nil when the phase has no heading; an already-skipped
    // heading returns the input unchanged.
    static func markingPhaseSkipped(_ number: Int, in markdown: String) -> String? {
        guard let phase = phase(numbered: number, in: markdown) else { return nil }
        guard !phase.skipped else { return markdown }
        var lines = markdown.components(separatedBy: "\n")
        guard let index = lines.firstIndex(of: phase.heading) else { return nil }
        lines[index] = phase.heading + " — \u{23F8} skipped"
        return lines.joined(separator: "\n")
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

    // A per-phase routing annotation in a body: the first line that — after
    // trimming and dropping one leading "- " list marker — starts with
    // "<key>:" (ASCII case-insensitive) yields its trimmed remainder,
    // verbatim. Whole-line anchored so prose mentioning "the model: …"
    // mid-sentence can't trigger it; an empty value is no annotation.
    static func annotation(_ key: String, in body: String) -> String? {
        for raw in body.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- ") { line = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            guard line.count > key.count + 1,
                  line.prefix(key.count).lowercased() == key.lowercased(),
                  line[line.index(line.startIndex, offsetBy: key.count)] == ":" else { continue }
            let value = String(line.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { return value }
        }
        return nil
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
