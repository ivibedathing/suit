import Cocoa

// Cross-transcript search. The pane shows one live session's
// transcript; this makes the whole conversation history queryable — the context
// you lose steering several worktrees at once ("what did Claude do about the
// auth bug yesterday"). The corpus is Claude Code's own JSONL transcript store
// under ~/.claude/projects (live and historical alike land there), searched
// with the same ripgrep engine the project search uses, then each matching raw
// JSON line is parsed back into a readable snippet with parseTranscriptLine and
// grouped by session.

// Where the transcript JSONL lives. Resolves ~ from $HOME (not
// NSHomeDirectory()) so a harness can sandbox the corpus, matching
// ClaudeIntegration's convention.
func claudeProjectsDirectory() -> String {
    let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    return home + "/.claude/projects"
}

// A session's identity for the results grouping: which file, and how to label
// it (name + cwd + date).
struct TranscriptSessionInfo {
    let sessionId: String
    let displayName: String
    let cwd: String?
    let date: Date
}

// One matching transcript line, ready to render and to jump to.
struct TranscriptSearchResult {
    let session: TranscriptSessionInfo
    let transcriptPath: String
    let lineNumber: Int
    let snippet: String
    let matchRanges: [NSRange]
}

// Reads a transcript file's head to recover its cwd and (if present) the
// session summary line, for labeling historical files that aren't live
// sessions. Reads only a prefix — transcripts can be large.
func transcriptFileMeta(path: String, maxBytes: Int = 128 * 1024) -> (cwd: String?, summary: String?) {
    guard let handle = FileHandle(forReadingAtPath: path) else { return (nil, nil) }
    defer { try? handle.close() }
    let data = (try? handle.read(upToCount: maxBytes)) ?? Data()
    guard let text = String(data: data, encoding: .utf8) else { return (nil, nil) }
    var cwd: String?
    var summary: String?
    for line in text.split(separator: "\n") {
        guard let lineData = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
        if summary == nil, object["type"] as? String == "summary",
           let value = (object["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            summary = value
        }
        if cwd == nil, let value = object["cwd"] as? String, !value.isEmpty {
            cwd = value
        }
        if cwd != nil, summary != nil { break }
    }
    return (cwd, summary)
}

// The searcher: streams ripgrep over the JSONL corpus, converts each matching
// raw line into a readable snippet, and groups by session. Reuses
// RipgrepSearcher for the streaming/cancel/generation machinery; the raw JSON
// line ripgrep returns is re-parsed here so results read as conversation, not
// as escaped JSON.
final class TranscriptSearcher {
    // Batched results, main queue. Called repeatedly as output streams in.
    var onResults: (([TranscriptSearchResult]) -> Void)?
    // Main queue, once per search (unless cancelled). errorMessage is set on a
    // real ripgrep failure.
    var onFinished: ((_ truncated: Bool, _ errorMessage: String?) -> Void)?

    private let rg = RipgrepSearcher()
    private var root = claudeProjectsDirectory()
    private var query = ""
    // Session-info cache, keyed by absolute transcript path, so a file matched
    // many times is only resolved once per search.
    private var infoCache: [String: TranscriptSessionInfo] = [:]

    init() {
        rg.onMatches = { [weak self] matches in
            self?.handle(matches)
        }
        rg.onFinished = { [weak self] truncated, error in
            self?.onFinished?(truncated, error)
        }
    }

    func cancel() {
        rg.cancel()
    }

    func search(query: String) {
        self.query = query
        infoCache = [:]
        root = claudeProjectsDirectory()

        guard !query.isEmpty else {
            rg.cancel()
            onFinished?(false, nil)
            return
        }
        guard FileManager.default.fileExists(atPath: root) else {
            onFinished?(false, "No Claude transcripts found (\(root))")
            return
        }
        rg.start(RipgrepOptions(
            pattern: query,
            isRegex: false,
            caseSensitive: false,
            globs: "*.jsonl",
            rootDirectory: root,
            searchHidden: true,
            respectIgnore: false
        ))
    }

    private func handle(_ matches: [SearchMatch]) {
        var results: [TranscriptSearchResult] = []
        for match in matches {
            // A line can hit inside JSON structure (keys, tool plumbing) rather
            // than conversation text; snippet(for:) drops those, keeping only
            // lines whose parsed content actually contains the query.
            guard let (snippet, ranges) = Self.snippet(forRawLine: match.lineText, query: query) else { continue }
            let absolute = root + "/" + match.relativePath
            let info = sessionInfo(forPath: absolute, relativePath: match.relativePath)
            results.append(TranscriptSearchResult(
                session: info,
                transcriptPath: absolute,
                lineNumber: match.lineNumber,
                snippet: snippet,
                matchRanges: ranges
            ))
        }
        if !results.isEmpty {
            onResults?(results)
        }
    }

    private func sessionInfo(forPath path: String, relativePath: String) -> TranscriptSessionInfo {
        if let cached = infoCache[path] { return cached }
        let sessionId = ((relativePath as NSString).lastPathComponent as NSString).deletingPathExtension

        let info: TranscriptSessionInfo
        if let live = ClaudeSessionMonitor.shared.sessions.first(where: { $0.transcriptPath == path }) {
            info = TranscriptSessionInfo(
                sessionId: sessionId, displayName: live.displayName, cwd: live.cwd, date: live.updatedAt
            )
        } else {
            let meta = transcriptFileMeta(path: path)
            let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
            let name = meta.summary
                ?? meta.cwd.map { ($0 as NSString).lastPathComponent }
                ?? String(sessionId.prefix(8))
            info = TranscriptSessionInfo(
                sessionId: sessionId, displayName: name, cwd: meta.cwd, date: modified ?? .distantPast
            )
        }
        infoCache[path] = info
        return info
    }

    // Parses a raw JSONL line and returns the first parsed entry whose text
    // contains the query, plus the query's ranges within that text — the
    // readable snippet for a match. nil when no parsed entry contains the query
    // (a structural-only ripgrep hit).
    static func snippet(forRawLine raw: String, query: String) -> (String, [NSRange])? {
        for entry in parseTranscriptLine(raw) {
            let text = entry.plainText.replacingOccurrences(of: "\n", with: " ")
            let ranges = plainMatchRanges(in: text, query: query)
            if !ranges.isEmpty {
                return windowedSnippet(text, ranges: ranges)
            }
        }
        return nil
    }

    // Case-insensitive occurrences of `query` in `text` as UTF-16 ranges.
    static func plainMatchRanges(in text: String, query: String) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let ns = text as NSString
        var ranges: [NSRange] = []
        var searchStart = 0
        while searchStart < ns.length {
            let found = ns.range(
                of: query, options: [.caseInsensitive],
                range: NSRange(location: searchStart, length: ns.length - searchStart)
            )
            guard found.location != NSNotFound else { break }
            ranges.append(found)
            searchStart = found.location + max(found.length, 1)
        }
        return ranges
    }

    // Keeps a snippet short while ensuring the first match stays visible:
    // slides the window so the match isn't pushed off the truncated end, with
    // ellipses marking either trimmed side and the ranges shifted to suit.
    static func windowedSnippet(_ text: String, ranges: [NSRange], limit: Int = 280) -> (String, [NSRange]) {
        let ns = text as NSString
        guard ns.length > limit, let first = ranges.first else {
            return (text, ranges)
        }
        // Start ~40 chars before the first match so there's leading context.
        let lead = 40
        var start = max(0, first.location - lead)
        let prefixEllipsis = start > 0
        // Snap to a word boundary near the cut so we don't slice mid-word.
        if prefixEllipsis {
            let scanRange = NSRange(location: start, length: min(20, ns.length - start))
            let space = ns.range(of: " ", range: scanRange)
            if space.location != NSNotFound { start = space.location + 1 }
        }
        let ellipsisPrefixLen = prefixEllipsis ? 1 : 0
        var length = min(limit - ellipsisPrefixLen, ns.length - start)
        let suffixEllipsis = start + length < ns.length
        if suffixEllipsis { length = max(0, length - 1) }

        var snippet = ns.substring(with: NSRange(location: start, length: length))
        // The kept window starts at `start`; a prepended "…" shifts every range
        // right by one, so the net shift of an original range is start - 1.
        let shift = start - ellipsisPrefixLen
        var shifted: [NSRange] = []
        for range in ranges {
            let loc = range.location - shift
            guard loc >= ellipsisPrefixLen, loc + range.length <= ellipsisPrefixLen + (snippet as NSString).length else { continue }
            shifted.append(NSRange(location: loc, length: range.length))
        }
        if prefixEllipsis { snippet = "…" + snippet }
        if suffixEllipsis { snippet += "…" }
        return (snippet, shifted)
    }
}
