import Cocoa

// "What changed while I was away" markers (ROADMAP Phase 24): the async-
// delegation review. You start Claude sessions across a repo's worktrees, step
// away, and come back wanting *one* diff of everything that moved — not to
// re-inspect each worktree by hand.
//
// A marker records a per-repo checkpoint: every worktree's HEAD sha plus a
// timestamp. "What Changed Since Mark" then composes an aggregate diff across
// all of the repo's worktrees (each `git diff <marker-sha>`, which spans
// commits + staged + unstaged) into a single review set fed to the Phase 5
// diff machinery (diff tab, n/p walk, o open, c comment). Because the diff pane
// is driven by diff *text*, the composer just rewrites each worktree's file
// paths to be relative to the main checkout, so the changed-file list reads
// "worktree/file" and attribution is visible in the walk.
//
// MarkerStore is the persistence (FavoritesStore's pattern); MarkerCatchUp is
// the pure git + string composition, with its transforms split out as static
// string functions so the path-rewriting is testable without a live app.

final class MarkerStore {
    static let shared = MarkerStore()
    static let didUpdate = Notification.Name("MarkerStoreDidUpdate")

    // One worktree's state at mark time.
    struct WorktreeMark: Codable {
        let path: String
        let branch: String?
        let sha: String
    }

    // A repo-wide checkpoint: when it was dropped, and every worktree's HEAD.
    struct Marker: Codable {
        let at: TimeInterval
        let worktrees: [WorktreeMark]
    }

    private struct Model: Codable {
        // Optional so an older/absent markers.json still decodes. Keyed by the
        // repo's main-checkout path (markers are repo-wide, not per-worktree).
        var markers: [String: Marker]?
    }

    private var model = Model()

    // $HOME rather than NSHomeDirectory() so tests/harnesses can point the
    // store at a scratch home (same reasoning as FavoritesStore/Notes).
    private var fileURL: URL {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: home + "/.suit/markers.json")
    }

    private init() {
        load()
    }

    func marker(forRepo mainRoot: String) -> Marker? {
        model.markers?[mainRoot]
    }

    func setMarker(_ marker: Marker, forRepo mainRoot: String) {
        var markers = model.markers ?? [:]
        markers[mainRoot] = marker
        model.markers = markers
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Model.self, from: data) else { return }
        model = decoded
    }

    private func save() {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(model) {
            try? data.write(to: fileURL, options: .atomic)
        }
        NotificationCenter.default.post(name: Self.didUpdate, object: self)
    }
}

// The git + composition side. Static so the string transforms can be exercised
// without an app (see the scratch tests): the pure functions take strings, the
// git-touching ones shell out via `runProcess`.
enum MarkerCatchUp {
    struct WorktreeInfo {
        let path: String
        let branch: String?
        let head: String
    }

    // Per-worktree line of the catch-up summary header.
    struct WorktreeSummary {
        let name: String        // "slug (task/slug)"
        let files: Int
        let insertions: Int
        let deletions: Int
        let sessionLabel: String?
        let hasChanges: Bool
    }

    struct Composed {
        let diffText: String
        let summaries: [WorktreeSummary]
        let totalFiles: Int
        let totalInsertions: Int
        let totalDeletions: Int
    }

    // MARK: - Git

    // The repo's main checkout, from any of its worktrees — the first "worktree "
    // entry of the porcelain listing (mirrors WorktreeTasks.mainRoot).
    static func mainRoot(_ anyRoot: String) -> String? {
        guard FileIndex.gitRoot(of: anyRoot) != nil else { return nil }
        return worktrees(mainRoot: anyRoot).first?.path
    }

    // `git worktree list --porcelain`: blocks of "worktree <path>" / "HEAD <sha>"
    // / "branch refs/heads/<name>" separated by blank lines.
    static func worktrees(mainRoot: String) -> [WorktreeInfo] {
        parseWorktrees(runProcess("/usr/bin/git", ["-C", mainRoot, "worktree", "list", "--porcelain"]) ?? "")
    }

    // Records the current state of every worktree as a marker.
    static func mark(mainRoot: String) -> MarkerStore.Marker {
        let marks = worktrees(mainRoot: mainRoot).map {
            MarkerStore.WorktreeMark(path: $0.path, branch: $0.branch, sha: $0.head)
        }
        return MarkerStore.Marker(at: Date().timeIntervalSince1970, worktrees: marks)
    }

    // The aggregate catch-up: every current worktree diffed against its marked
    // sha (falling back to a merge-base for worktrees created after the mark),
    // rewritten into one review set. `sessionForPath` injects the Claude-session
    // attribution so this stays free of the session monitor.
    static func compose(mainRoot: String, marker: MarkerStore.Marker,
                        sessionForPath: (String) -> String?) -> Composed {
        let markSha = Dictionary(marker.worktrees.map { ($0.path, $0.sha) }, uniquingKeysWith: { a, _ in a })
        let mainMarkSha = marker.worktrees.first?.sha

        var sections: [String] = []
        var summaries: [WorktreeSummary] = []
        var totalFiles = 0, totalIns = 0, totalDel = 0

        for wt in worktrees(mainRoot: mainRoot) {
            guard let base = baseSha(for: wt, markSha: markSha, mainMarkSha: mainMarkSha) else { continue }
            // Tracked changes since the base: commits + staged + unstaged.
            let tracked = runProcess("/usr/bin/git", ["-C", wt.path, "diff", base]) ?? ""
            var stat = parseNumstat(runProcess("/usr/bin/git", ["-C", wt.path, "diff", "--numstat", base]) ?? "")

            // Untracked files: `git diff` omits them, but a file Claude just
            // created is exactly "what moved" while you were away. Each is
            // diffed against /dev/null so it renders as a whole-file addition.
            var untracked = ""
            for rel in untrackedFiles(root: wt.path) {
                let addition = runProcess("/usr/bin/git", ["-C", wt.path, "diff", "--no-index", "--", "/dev/null", rel]) ?? ""
                guard !addition.isEmpty else { continue }
                untracked += addition
                stat.files += 1
                stat.insertions += additionCount(addition)
            }
            let combined = tracked + untracked

            let prefix = pathPrefix(mainRoot: mainRoot, worktree: wt.path)
            let name = (wt.path as NSString).lastPathComponent
            let label = "\(name) (\(wt.branch ?? "detached"))"
            let hasChanges = !combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            summaries.append(WorktreeSummary(
                name: label, files: stat.files, insertions: stat.insertions,
                deletions: stat.deletions, sessionLabel: sessionForPath(wt.path),
                hasChanges: hasChanges
            ))
            totalFiles += stat.files
            totalIns += stat.insertions
            totalDel += stat.deletions

            if hasChanges {
                sections.append(prefixPaths(combined, prefix: prefix))
            }
        }

        let diffText = preamble(summaries: summaries, at: marker.at,
                                totalFiles: totalFiles, totalIns: totalIns, totalDel: totalDel)
            + sections.joined()
        return Composed(diffText: diffText, summaries: summaries,
                        totalFiles: totalFiles, totalInsertions: totalIns, totalDeletions: totalDel)
    }

    // The base a worktree is diffed against: its own marked sha, else — for a
    // worktree created since the mark — the merge-base with the marked main sha
    // (so only its new work shows, not the whole shared history).
    private static func baseSha(for wt: WorktreeInfo, markSha: [String: String], mainMarkSha: String?) -> String? {
        if let sha = markSha[wt.path], !sha.isEmpty { return sha }
        guard let mainMarkSha, !mainMarkSha.isEmpty else { return nil }
        if let mb = runProcess("/usr/bin/git", ["-C", wt.path, "merge-base", mainMarkSha, "HEAD"])?
            .trimmingCharacters(in: .whitespacesAndNewlines), !mb.isEmpty {
            return mb
        }
        return mainMarkSha
    }

    // MARK: - Pure parsing / transforms (tested standalone)

    static func parseWorktrees(_ porcelain: String) -> [WorktreeInfo] {
        var result: [WorktreeInfo] = []
        var path: String?
        var head: String?
        var branch: String?
        func flush() {
            if let path { result.append(WorktreeInfo(path: path, branch: branch, head: head ?? "")) }
            path = nil; head = nil; branch = nil
        }
        for raw in porcelain.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            if line.hasPrefix("worktree ") {
                flush()
                path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("HEAD ") {
                head = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch refs/heads/") {
                branch = String(line.dropFirst("branch refs/heads/".count))
            }
        }
        flush()
        return result
    }

    // Newly-created (untracked, non-ignored) files in a worktree.
    static func untrackedFiles(root: String) -> [String] {
        (runProcess("/usr/bin/git", ["-C", root, "ls-files", "--others", "--exclude-standard"]) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    // Added lines in a diff (excluding the +++ file header) — the insertion
    // count for a whole-file --no-index addition, which numstat doesn't cover.
    static func additionCount(_ diff: String) -> Int {
        var count = 0
        diff.enumerateLines { line, _ in
            if line.hasPrefix("+"), !line.hasPrefix("+++") { count += 1 }
        }
        return count
    }

    static func parseNumstat(_ text: String) -> (files: Int, insertions: Int, deletions: Int) {
        var files = 0, ins = 0, del = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = raw.split(separator: "\t")
            guard parts.count >= 3 else { continue }
            files += 1
            // Binary files report "-" for both counts; Int() fails → 0.
            ins += Int(parts[0]) ?? 0
            del += Int(parts[1]) ?? 0
        }
        return (files, ins, del)
    }

    // The worktree's path relative to the main checkout, with a trailing slash
    // (empty for the main checkout itself) — the prefix stitched into every
    // diff path so the aggregate resolves back to real files under one root.
    static func pathPrefix(mainRoot: String, worktree: String) -> String {
        let rel = relativePath(from: mainRoot, to: worktree)
        return rel.isEmpty ? "" : rel + "/"
    }

    // A component-wise relative path (handles worktrees that live outside the
    // main checkout via "..") — resolved back by NSString.standardizingPath on
    // open, so `o` and the changed-file list point at the real file.
    static func relativePath(from base: String, to target: String) -> String {
        let b = (base as NSString).standardizingPath.split(separator: "/").map(String.init)
        let t = (target as NSString).standardizingPath.split(separator: "/").map(String.init)
        var i = 0
        while i < b.count, i < t.count, b[i] == t[i] { i += 1 }
        let up = Array(repeating: "..", count: b.count - i)
        let down = Array(t[i...])
        return (up + down).joined(separator: "/")
    }

    // Rewrites every file path in a unified diff to sit under `prefix`, leaving
    // /dev/null (new/deleted-file sentinels) and diff content untouched. Keeps
    // the b/ side consistent with UnifiedDiffParser.changedPaths so the review
    // walk and inline anchors line up.
    static func prefixPaths(_ diff: String, prefix: String) -> String {
        if prefix.isEmpty { return diff }
        var lines: [String] = []
        diff.enumerateLines { line, _ in lines.append(rewriteLine(line, prefix: prefix)) }
        return lines.joined(separator: "\n") + (diff.hasSuffix("\n") ? "\n" : "")
    }

    static func rewriteLine(_ line: String, prefix: String) -> String {
        if line.hasPrefix("diff --git ") {
            return "diff --git " + rewriteHeaderPaths(String(line.dropFirst("diff --git ".count)), prefix: prefix)
        }
        if line.hasPrefix("--- ") { return "--- " + rewriteSide(String(line.dropFirst(4)), prefix: prefix) }
        if line.hasPrefix("+++ ") { return "+++ " + rewriteSide(String(line.dropFirst(4)), prefix: prefix) }
        for keyword in ["rename from ", "rename to ", "copy from ", "copy to "] where line.hasPrefix(keyword) {
            return keyword + prefix + String(line.dropFirst(keyword.count))
        }
        return line
    }

    // "a/<path> b/<path>" → both sides prefixed (split on " b/", matching the
    // parser's own naive split so paths with spaces stay consistent).
    private static func rewriteHeaderPaths(_ s: String, prefix: String) -> String {
        guard let range = s.range(of: " b/") else { return s }
        let a = String(s[..<range.lowerBound])
        let b = String(s[range.upperBound...])
        let aRewritten = a.hasPrefix("a/") ? "a/" + prefix + String(a.dropFirst(2)) : a
        return aRewritten + " b/" + prefix + b
    }

    private static func rewriteSide(_ s: String, prefix: String) -> String {
        if s.hasPrefix("/dev/null") { return s }
        if s.hasPrefix("a/") { return "a/" + prefix + String(s.dropFirst(2)) }
        if s.hasPrefix("b/") { return "b/" + prefix + String(s.dropFirst(2)) }
        return s
    }

    // MARK: - Header

    // The summary block that leads the aggregate diff: an overall line plus one
    // line per worktree (files / +ins −del / which session). Rendered as plain
    // context lines by the diff pane — kept clear of +/-/@ so the parser never
    // mistakes them for diff content.
    static func preamble(summaries: [WorktreeSummary], at: TimeInterval,
                         totalFiles: Int, totalIns: Int, totalDel: Int) -> String {
        let touched = summaries.filter { $0.hasChanges }.count
        var lines = [
            "Catch-up since \(shortTime(at)) — \(fileCount(totalFiles)), +\(totalIns) \u{2212}\(totalDel) across \(touched) worktree\(touched == 1 ? "" : "s")",
            "",
        ]
        for s in summaries where s.hasChanges {
            var line = "\(s.name) — \(fileCount(s.files)), +\(s.insertions) \u{2212}\(s.deletions)"
            if let session = s.sessionLabel { line += " · session: \(session)" }
            lines.append(line)
        }
        if summaries.contains(where: { $0.hasChanges }) { lines.append("") }
        return lines.joined(separator: "\n") + "\n"
    }

    static func fileCount(_ n: Int) -> String { "\(n) file\(n == 1 ? "" : "s")" }

    // A compact, human "Jul 7, 2:30 PM" for the header and the diff-tab title.
    static func shortTime(_ at: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter.string(from: Date(timeIntervalSince1970: at))
    }
}
