import Foundation

// Symbol-aware navigation (ROADMAP Phase 33): the Navigate pillar goes semantic.
// Phases 1–2 gave fuzzy-open and text search; this adds go-to-definition and
// find-references over a ctags symbol index. Read-only, like the viewer.
//
// This file is Foundation-only (no Cocoa) so the pure parsing / resolution /
// navigation logic can be compiled and asserted by scripts/symbol-index-test.sh
// in isolation — the RoadmapParser / FeedbackRouting / AutopilotScheduler
// pattern. A light LSP client is the sanctioned swap-in later (same
// definition/reference output), exactly as SyntaxHighlighter leaves room for
// tree-sitter.

// One symbol occurrence from the index: what it is, where it lives (path
// relative to the index root — the ctags run cwd — so the UI prepends the root
// exactly like a SearchMatch), and its 1-based line.
struct Symbol: Equatable {
    let name: String
    let relativePath: String
    let line: Int
    let kind: String
}

// Where "go to definition" lands, given the definitions the index holds for an
// identifier. Zero → nothing to jump to (fall back to a references/word search);
// one → jump straight there; many → let the user pick (references pane / palette
// picker), so an overloaded or shadowed name never silently jumps to the wrong
// one.
enum GotoOutcome: Equatable {
    case none
    case jump(Symbol)
    case choose([Symbol])
}

enum SymbolNavigation {
    static func gotoOutcome(for defs: [Symbol]) -> GotoOutcome {
        switch defs.count {
        case 0: return .none
        case 1: return .jump(defs[0])
        default: return .choose(defs)
        }
    }

    // The header line the references pane shows above its results. When ctags
    // wasn't available the list is a plain identifier word-search (rg), so the
    // note says so — the "degrades to an rg-word-search fallback with a header
    // note" the roadmap calls for.
    static func headerNote(symbol: String, ctagsAvailable: Bool) -> String {
        if ctagsAvailable {
            return "References to “\(symbol)”"
        }
        return "References to “\(symbol)” — ctags unavailable, showing text matches"
    }

    // The ripgrep pattern that finds every use of an identifier: a whole-word
    // regex (\bfoo\b) so `foo` doesn't match `foobar`. Non-identifier input (a
    // stray terminal selection) is regex-escaped and left unbounded so the
    // search still runs instead of erroring on a bad pattern.
    static func wordSearchPattern(for symbol: String) -> String {
        let isIdentifier = !symbol.isEmpty && symbol.unicodeScalars.allSatisfy { SymbolLookup.isIdentifierChar($0) }
        if isIdentifier {
            return "\\b\(symbol)\\b"
        }
        return NSRegularExpression.escapedPattern(for: symbol)
    }
}

// Pulls the identifier token straddling a character offset out of a line of
// text: the maximal run of identifier characters (letters, digits, underscore)
// containing — or immediately adjacent to — the offset. Pure so the click →
// symbol path can be asserted without a text view.
enum SymbolLookup {
    static func isIdentifierChar(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "_" || (scalar.value < 128 && (
            (scalar >= "a" && scalar <= "z") ||
            (scalar >= "A" && scalar <= "Z") ||
            (scalar >= "0" && scalar <= "9")
        ))
    }

    // `offset` is a UTF-16 offset into `line` (what NSTextView hands back), so
    // the arithmetic matches the view's character indexing exactly.
    static func identifier(in line: String, atUTF16Offset offset: Int) -> String? {
        let units = Array(line.utf16)
        guard !units.isEmpty else { return nil }
        // A click just past the last character (offset == count) still resolves
        // the token it abuts, matching how editors treat an end-of-word caret.
        var index = min(max(offset, 0), units.count)

        func isIdent(_ u: UInt16) -> Bool {
            guard let scalar = Unicode.Scalar(u) else { return false }
            return isIdentifierChar(scalar)
        }

        // If the offset sits between two non-identifier characters, try the
        // character just to the left (a caret at the end of a word).
        if index >= units.count || !isIdent(units[index]) {
            if index > 0, isIdent(units[index - 1]) {
                index -= 1
            } else {
                return nil
            }
        }

        var start = index
        while start > 0, isIdent(units[start - 1]) { start -= 1 }
        var end = index
        while end < units.count, isIdent(units[end]) { end += 1 }
        guard end > start else { return nil }
        return String(decoding: Array(units[start..<end]), as: UTF16.self)
    }
}

// Resolves the universal-ctags binary the same three ways ripgrep is resolved
// (see resolveRipgrepExecutable): SUIT_CTAGS_PATH override → the copy bundled
// into Contents/Resources by build.sh → common Homebrew/local install paths.
//
// Deliberately does NOT fall back to /usr/bin/ctags: on macOS that's BSD ctags,
// which doesn't speak the JSON output format the parser expects — picking it up
// would produce empty results that look like "no symbols" rather than a clean
// "ctags unavailable" fallback to the rg word search.
func resolveCtagsExecutable() -> String? {
    let fm = FileManager.default
    if let envPath = ProcessInfo.processInfo.environment["SUIT_CTAGS_PATH"],
       fm.isExecutableFile(atPath: envPath) {
        return envPath
    }
    if let resourcePath = Bundle.main.resourcePath {
        let bundled = resourcePath + "/ctags"
        if fm.isExecutableFile(atPath: bundled) {
            return bundled
        }
    }
    for candidate in [
        "/opt/homebrew/bin/ctags",
        "/usr/local/bin/ctags",
    ] where fm.isExecutableFile(atPath: candidate) {
        return candidate
    }
    return nil
}

// The per-git-root symbol index. Runs universal-ctags over the FileIndex file
// list (fed in by the caller so this stays Cocoa-free), off the main thread,
// caching one instance per root and marking itself stale on FileIndex.didUpdate
// (the app layer calls markStale). Lookups ensure the index is built before
// answering, so the first go-to-def after opening a repo just works.
final class SymbolIndex {
    let root: String

    // Whether the last build actually ran ctags. false → no binary (or it
    // failed); callers degrade go-to-def / find-references to an rg word search.
    private(set) var isCtagsAvailable = false

    private var byName: [String: [Symbol]] = [:]
    private var builtGeneration = 0     // last generation whose results landed
    private var startedGeneration = 0   // last generation kicked off
    private var stale = true

    private let queue = DispatchQueue(label: "dev.kosych.suit.symbolindex", qos: .userInitiated)

    init(root: String) {
        self.root = root
    }

    // MARK: - Per-root cache

    private static var instances: [String: SymbolIndex] = [:]
    private static let cacheLock = NSLock()

    static func shared(forRoot root: String) -> SymbolIndex {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let existing = instances[root] { return existing }
        let created = SymbolIndex(root: root)
        instances[root] = created
        return created
    }

    // FSEvents fired for a root (FileIndex.didUpdate): mark its index stale so
    // the next lookup rebuilds — but only if one was ever built, so we don't
    // spin up ctags indices for repos the user never navigated symbolically.
    static func markStaleIfExists(forRoot root: String) {
        cacheLock.lock()
        let existing = instances[root]
        cacheLock.unlock()
        existing?.markStale()
    }

    // The file index for this root changed (FSEvents) — the next lookup
    // rebuilds. Cheap: just a flag, the actual ctags run is deferred to use.
    func markStale() {
        queue.async { self.stale = true }
    }

    // MARK: - Lookup

    // Ensures the index is fresh (rebuilding from `files` if stale), then hands
    // the definitions for `name` back on the main queue along with whether ctags
    // was available. `files` is captured lazily so a fresh build sees the
    // current file list without the caller pre-reading it every lookup.
    func definitions(named name: String,
                     files: @escaping () -> [String],
                     completion: @escaping (_ defs: [Symbol], _ ctagsAvailable: Bool) -> Void) {
        queue.async {
            if self.stale || self.builtGeneration == 0 {
                self.rebuildSync(files: files())
            }
            let defs = self.byName[name] ?? []
            let available = self.isCtagsAvailable
            DispatchQueue.main.async { completion(defs, available) }
        }
    }

    // Force a rebuild now (used when the app wants to warm the index). Runs on
    // the private queue; the completion fires on the main queue.
    func rebuild(files: @escaping () -> [String], completion: (() -> Void)? = nil) {
        queue.async {
            self.rebuildSync(files: files())
            if let completion { DispatchQueue.main.async { completion() } }
        }
    }

    // MUST be called on `queue`. Runs ctags over the file list and rebuilds the
    // name → symbols map. A missing binary or a launch failure leaves the map
    // empty and isCtagsAvailable false (the rg fallback territory).
    private func rebuildSync(files: [String]) {
        startedGeneration += 1
        let generation = startedGeneration
        stale = false

        guard let ctags = resolveCtagsExecutable() else {
            isCtagsAvailable = false
            byName = [:]
            builtGeneration = generation
            return
        }

        let output = Self.runCtags(executable: ctags, root: root, files: files)
        // Only accept results if no newer build started while ctags ran.
        guard generation == startedGeneration else { return }

        if let output {
            byName = Self.index(Self.parseTags(output))
            isCtagsAvailable = true
        } else {
            byName = [:]
            isCtagsAvailable = false
        }
        builtGeneration = generation
    }

    // MARK: - ctags invocation

    static func ctagsArguments() -> [String] {
        // JSON output with line numbers + full kind names; read the file list
        // from stdin (-L -) and write tags to stdout (-f -). --languages=all so
        // ctags picks the parser per extension, matching the file index.
        [
            "--output-format=json",
            "--fields=+nK",
            "--languages=all",
            "-L", "-",
            "-f", "-",
        ]
    }

    // Runs ctags with the file list piped on stdin (avoids a giant argv and any
    // per-path quoting hazard, the way AutopilotReviewGate feeds the review
    // prompt on stdin). Returns the JSON-lines stdout, or nil on a launch/exit
    // failure so the caller can fall back.
    static func runCtags(executable: String, root: String, files: [String]) -> String? {
        guard !files.isEmpty else { return "" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ctagsArguments()
        process.currentDirectoryURL = URL(fileURLWithPath: root)

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return nil
        }

        // Write the file list, then close stdin so ctags starts processing.
        let list = files.joined(separator: "\n") + "\n"
        stdinPipe.fileHandleForWriting.write(Data(list.utf8))
        stdinPipe.fileHandleForWriting.closeFile()

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        _ = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        // ctags exits 0 on success. A non-zero exit with no output is a real
        // failure (bad binary); tolerate a non-zero exit that still produced
        // tags (some versions warn on unreadable files).
        if process.terminationStatus != 0 && data.isEmpty {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Parsing (pure)

    // One universal-ctags `--output-format=json` line per tag, e.g.
    //   {"_type":"tag","name":"foo","path":"a.swift","line":12,"kind":"function"}
    // Non-tag lines (pseudo-tags, blank lines, malformed JSON) are skipped.
    static func parseTags(_ output: String) -> [Symbol] {
        var symbols: [Symbol] = []
        output.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            // universal-ctags emits _type:"tag" for real tags and _type:"ptag"
            // for pseudo-tags; accept a missing _type defensively.
            if let type = object["_type"] as? String, type != "tag" { return }
            guard let name = object["name"] as? String,
                  let path = object["path"] as? String else { return }
            let line = (object["line"] as? Int) ?? Int(object["line"] as? String ?? "") ?? 0
            let kind = (object["kind"] as? String) ?? ""
            symbols.append(Symbol(name: name, relativePath: path, line: line, kind: kind))
        }
        return symbols
    }

    // Groups symbols by name for O(1) definition lookup, preserving encounter
    // order within a name (file order) so a picker lists them stably.
    static func index(_ symbols: [Symbol]) -> [String: [Symbol]] {
        var map: [String: [Symbol]] = [:]
        for symbol in symbols {
            map[symbol.name, default: []].append(symbol)
        }
        return map
    }
}
