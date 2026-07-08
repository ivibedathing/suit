import Foundation

// Project-wide search (ROADMAP Phase 2) shells out to `rg --json` rather than
// implementing a search engine — ripgrep is the industry answer (VSCode does
// exactly this). The binary ships in Contents/Resources so search doesn't
// depend on the user's PATH; the fallbacks mirror resolveTUIExecutable().
func resolveRipgrepExecutable() -> String? {
    let fm = FileManager.default
    if let envPath = ProcessInfo.processInfo.environment["SUIT_RG_PATH"],
       fm.isExecutableFile(atPath: envPath) {
        return envPath
    }
    if let resourcePath = Bundle.main.resourcePath {
        let bundled = resourcePath + "/rg"
        if fm.isExecutableFile(atPath: bundled) {
            return bundled
        }
    }
    // Dev `swiftc` runs have no bundle Resources; take any common install.
    for candidate in [
        "/opt/homebrew/bin/rg",
        "/usr/local/bin/rg",
        NSHomeDirectory() + "/.local/share/opencode/bin/rg",
    ] where fm.isExecutableFile(atPath: candidate) {
        return candidate
    }
    return nil
}

// One matched line: where it is, its text, and which character ranges of that
// text matched (for bolding in the results list).
struct SearchMatch {
    let relativePath: String
    let lineNumber: Int
    let lineText: String
    let matchRanges: [NSRange]
}

// Named to avoid colliding with SwiftTerm's SearchOptions (vendored sources
// compile into the same module as ours).
struct RipgrepOptions {
    var pattern: String
    var isRegex: Bool
    var caseSensitive: Bool
    // Comma/space-separated rg -g globs, e.g. "*.swift, go/**".
    var globs: String
    var rootDirectory: String
    // Cross-transcript search (Phase 20) searches ~/.claude — a hidden tree that
    // may carry its own ignore rules — so it opts into --hidden/--no-ignore.
    // Project search leaves both at their defaults (respect .gitignore, skip
    // dotfiles), matching VSCode.
    var searchHidden = false
    var respectIgnore = true
}

// One in-flight `rg --json` run. Streams stdout, parses the JSON-lines events,
// and delivers matches to the main queue in batches (that's the "live-updating"
// in the roadmap: big trees show hits as they're found, not after the walk).
// Starting a new search cancels the previous one; results are capped so a
// too-broad pattern over a large repo can't accumulate memory without bound.
final class RipgrepSearcher {
    static let maxMatches = 2_000

    // Batched matches, main queue. Called repeatedly as output streams in.
    var onMatches: (([SearchMatch]) -> Void)?
    // Main queue, exactly once per started search (unless cancelled).
    // `errorMessage` is rg's stderr for real failures (e.g. a bad regex).
    var onFinished: ((_ truncated: Bool, _ errorMessage: String?) -> Void)?

    private var process: Process?
    // Incremented on every start/cancel; parsing closures capture the value
    // they were started under and drop their output if it has moved on.
    private var generation = 0
    private let parseQueue = DispatchQueue(label: "dev.kosych.suit.search", qos: .userInitiated)

    func cancel() {
        generation += 1
        if let process, process.isRunning {
            process.terminationHandler = nil
            process.standardOutput.flatMap { ($0 as? Pipe)?.fileHandleForReading.readabilityHandler = nil }
            process.terminate()
        }
        process = nil
    }

    func start(_ options: RipgrepOptions) {
        cancel()
        guard let rgPath = resolveRipgrepExecutable() else {
            onFinished?(false, "ripgrep binary not found — rebuild the app or set SUIT_RG_PATH")
            return
        }

        generation += 1
        let expected = generation

        var arguments = ["--json"]
        if !options.caseSensitive {
            arguments.append("--ignore-case")
        }
        if !options.isRegex {
            arguments.append("--fixed-strings")
        }
        if options.searchHidden {
            arguments.append("--hidden")
        }
        if !options.respectIgnore {
            arguments.append("--no-ignore")
        }
        for glob in options.globs.split(whereSeparator: { $0 == "," || $0 == " " }) where !glob.isEmpty {
            arguments.append(contentsOf: ["--glob", String(glob)])
        }
        // -e so patterns starting with "-" aren't taken as flags; no path
        // argument — rg searches its cwd, which makes reported paths
        // scope-relative for free.
        arguments.append(contentsOf: ["--regexp", options.pattern])

        let process = Process()
        process.executableURL = URL(fileURLWithPath: rgPath)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: options.rootDirectory)

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        var lineBuffer = Data()
        var matchCount = 0
        var truncated = false

        // Streamed parsing happens on parseQueue; the readability handler only
        // hops there, so rg is never blocked writing while we parse.
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.parseQueue.async {
                guard let self, self.generation == expected, !truncated else { return }
                lineBuffer.append(chunk)
                var matches: [SearchMatch] = []
                while let newline = lineBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = lineBuffer.prefix(upTo: newline)
                    lineBuffer.removeSubrange(...newline)
                    if let match = Self.parseMatchEvent(line) {
                        matches.append(match)
                        matchCount += 1
                        if matchCount >= Self.maxMatches {
                            truncated = true
                            break
                        }
                    }
                }
                if !matches.isEmpty {
                    DispatchQueue.main.async {
                        guard self.generation == expected else { return }
                        self.onMatches?(matches)
                    }
                }
                if truncated {
                    DispatchQueue.main.async {
                        guard self.generation == expected else { return }
                        // Enough results to look at; stop rg rather than
                        // draining (and discarding) the rest of the tree.
                        self.cancel()
                        self.onFinished?(true, nil)
                    }
                }
            }
        }

        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            stdout.fileHandleForReading.readabilityHandler = nil
            let remaining = try? stdout.fileHandleForReading.readToEnd()
            let errorData = try? stderr.fileHandleForReading.readToEnd()
            self?.parseQueue.async {
                guard let self, self.generation == expected else { return }
                if let remaining, !truncated {
                    lineBuffer.append(remaining)
                    var matches: [SearchMatch] = []
                    for line in lineBuffer.split(separator: UInt8(ascii: "\n")) {
                        if matchCount >= Self.maxMatches {
                            truncated = true
                            break
                        }
                        if let match = Self.parseMatchEvent(line) {
                            matches.append(match)
                            matchCount += 1
                        }
                    }
                    if !matches.isEmpty {
                        DispatchQueue.main.async {
                            guard self.generation == expected else { return }
                            self.onMatches?(matches)
                        }
                    }
                }
                // rg exits 1 for "no matches", which isn't an error; 2 means a
                // real failure (bad regex/glob) worth surfacing.
                var errorMessage: String?
                if status != 0 && status != 1,
                   let errorData, let text = String(data: errorData, encoding: .utf8) {
                    let firstLine = text.split(separator: "\n").first.map(String.init) ?? text
                    errorMessage = firstLine.trimmingCharacters(in: .whitespaces)
                }
                DispatchQueue.main.async {
                    guard self.generation == expected else { return }
                    self.process = nil
                    self.onFinished?(truncated, errorMessage)
                }
            }
        }

        self.process = process
        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            self.process = nil
            onFinished?(false, "could not launch ripgrep: \(error.localizedDescription)")
        }
    }

    // MARK: - JSON-lines parsing

    // One `rg --json` event → a SearchMatch if it's a "match" event, nil for
    // everything else (begin/end/summary/context). Byte offsets from rg are
    // converted to UTF-16 ranges so the UI can hand them to NSAttributedString.
    static func parseMatchEvent<D: DataProtocol>(_ line: D) -> SearchMatch? {
        let data = Data(line)
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "match",
              let payload = object["data"] as? [String: Any],
              let pathInfo = payload["path"] as? [String: Any],
              let path = pathInfo["text"] as? String,
              let lineNumber = payload["line_number"] as? Int,
              let linesInfo = payload["lines"] as? [String: Any],
              // "bytes" instead of "text" means non-UTF-8 content; skip those
              // rather than showing mojibake.
              let rawLineText = linesInfo["text"] as? String
        else { return nil }

        let lineText = rawLineText.hasSuffix("\n") ? String(rawLineText.dropLast()) : rawLineText

        var ranges: [NSRange] = []
        if let submatches = payload["submatches"] as? [[String: Any]] {
            let utf8 = Array(lineText.utf8)
            for submatch in submatches {
                guard let start = submatch["start"] as? Int,
                      let end = submatch["end"] as? Int,
                      start >= 0, end <= utf8.count, start < end else { continue }
                // rg reports byte offsets into the line; NSRange wants UTF-16.
                let prefix = String(decoding: utf8[0..<start], as: UTF8.self)
                let body = String(decoding: utf8[start..<end], as: UTF8.self)
                ranges.append(NSRange(location: prefix.utf16.count, length: body.utf16.count))
            }
        }

        return SearchMatch(relativePath: path, lineNumber: lineNumber, lineText: lineText, matchRanges: ranges)
    }
}
