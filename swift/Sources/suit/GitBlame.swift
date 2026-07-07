import Cocoa

// Git blame + per-file history (ROADMAP Phase 17): read-only context around the
// open file — "who and what last changed this line, and why". Both reads run
// off the main thread and hand their result back on the main queue, mirroring
// GitChangedLines so the viewer can consume them the same way.

// One blamed line: the commit that last touched it. `sha` is the full hash (for
// chaining to a diff), `shortSha` the abbreviated form the gutter shows.
// `time` is the author timestamp (0 while uncommitted) used for age tinting.
struct BlameLine {
    let sha: String
    let shortSha: String
    let author: String
    let time: TimeInterval
    let summary: String

    // git marks not-yet-committed lines with the all-zero sha.
    var isUncommitted: Bool { sha.allSatisfy { $0 == "0" } }
}

enum GitBlame {
    // `git blame --porcelain` groups lines by commit: a "<40-hex> <orig> <final>
    // <count>" header (count only on a group's first line), the commit metadata
    // the first time each sha appears, then the "\t"-prefixed source line. We
    // key metadata by sha so later groups reuse the first occurrence's fields.
    static func compute(filePath: String, completion: @escaping ([Int: BlameLine]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let directory = (filePath as NSString).deletingLastPathComponent
            guard let root = FileIndex.gitRoot(of: directory),
                  let output = runProcess("/usr/bin/git", ["-C", root, "blame", "--porcelain", "--", filePath]) else {
                DispatchQueue.main.async { completion([:]) }
                return
            }
            let parsed = parse(output)
            DispatchQueue.main.async { completion(parsed) }
        }
    }

    // Split out for the verification harness.
    static func parse(_ output: String) -> [Int: BlameLine] {
        struct Meta { var author = ""; var time: TimeInterval = 0; var summary = "" }
        var metaBySha: [String: Meta] = [:]
        var result: [Int: BlameLine] = [:]

        var currentSha = ""
        var currentLine = 0

        output.enumerateLines { line, _ in
            if line.hasPrefix("\t") {
                // End of an entry — emit the blamed line from the accumulated
                // metadata for its commit.
                let meta = metaBySha[currentSha] ?? Meta()
                result[currentLine] = BlameLine(
                    sha: currentSha,
                    shortSha: String(currentSha.prefix(8)),
                    author: meta.author,
                    time: meta.time,
                    summary: meta.summary
                )
                return
            }
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
            if let first = fields.first, first.count == 40, first.allSatisfy({ $0.isHexDigit }) {
                // Header: "<sha> <origLine> <finalLine> [count]".
                currentSha = String(first)
                currentLine = fields.count > 2 ? (Int(fields[2]) ?? currentLine) : currentLine
                if metaBySha[currentSha] == nil { metaBySha[currentSha] = Meta() }
                return
            }
            // Commit metadata for currentSha (only present on first occurrence).
            if line.hasPrefix("author ") {
                metaBySha[currentSha]?.author = String(line.dropFirst("author ".count))
            } else if line.hasPrefix("author-time ") {
                metaBySha[currentSha]?.time = TimeInterval(line.dropFirst("author-time ".count)) ?? 0
            } else if line.hasPrefix("summary ") {
                metaBySha[currentSha]?.summary = String(line.dropFirst("summary ".count))
            }
        }
        return result
    }
}

// One commit touching the open file, for the Git tab's File History section.
struct FileCommit {
    let sha: String
    let shortSha: String
    let subject: String
    let author: String
    let time: TimeInterval
}

enum GitFileHistory {
    // `git log --follow` across renames. A unit-separator (\x1f) format keeps
    // subjects with spaces intact; one commit per line.
    static func compute(filePath: String, completion: @escaping (String?, [FileCommit]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let directory = (filePath as NSString).deletingLastPathComponent
            guard let root = FileIndex.gitRoot(of: directory),
                  let output = runProcess("/usr/bin/git", [
                    "-C", root, "log", "--follow", "--format=%H%x1f%h%x1f%an%x1f%at%x1f%s", "--", filePath,
                  ]) else {
                DispatchQueue.main.async { completion(nil, []) }
                return
            }
            let commits = parse(output)
            DispatchQueue.main.async { completion(root, commits) }
        }
    }

    static func parse(_ output: String) -> [FileCommit] {
        var commits: [FileCommit] = []
        output.enumerateLines { line, _ in
            let fields = line.components(separatedBy: "\u{1f}")
            guard fields.count == 5 else { return }
            commits.append(FileCommit(
                sha: fields[0],
                shortSha: fields[1],
                subject: fields[4],
                author: fields[2],
                time: TimeInterval(fields[3]) ?? 0
            ))
        }
        return commits
    }
}

// Shared age-tinting used by the blame gutter and history rows: recent commits
// read bright (textDim), fading to faint over ~2 years on a log scale so the
// last few days still separate visibly. Uncommitted lines take the amber accent.
enum GitAgeTint {
    static func color(forTime time: TimeInterval, now: TimeInterval) -> NSColor {
        guard time > 0 else { return Theme.accent }
        let ageDays = max(0, (now - time) / 86_400)
        // log2(1 + days) maps 0→0, 1d→1, 3d→2, 7d→3, … saturating near 2 years.
        let fraction = min(1, log2(1 + ageDays) / log2(1 + 730))
        return blend(Theme.textDim, Theme.textFaint, fraction)
    }

    private static func blend(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        guard let ca = a.usingColorSpace(.sRGB), let cb = b.usingColorSpace(.sRGB) else { return a }
        return NSColor(
            srgbRed: ca.redComponent + (cb.redComponent - ca.redComponent) * t,
            green: ca.greenComponent + (cb.greenComponent - ca.greenComponent) * t,
            blue: ca.blueComponent + (cb.blueComponent - ca.blueComponent) * t,
            alpha: 1
        )
    }
}
