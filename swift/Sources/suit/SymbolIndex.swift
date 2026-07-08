import Foundation

// The symbol index behind go-to-definition (ROADMAP Phase 33): runs
// universal-ctags over a project's FileIndex file list, caches the resulting
// definitions per git root, and refreshes when FileIndex's FSEvents watcher
// fires. The pure parsing/lookup lives in SymbolIndexCore.swift (standalone-
// testable); this is the process + caching + refresh shell, mirroring how
// FileIndex owns scanning and RipgrepSearcher owns the rg process. A light LSP
// client is the sanctioned swap-in later — same definition output — exactly as
// SyntaxHighlighter leaves room for tree-sitter.
//
// When no ctags binary is present the index simply stays empty; callers detect
// that via `hasCtags` and fall back to an rg word search (the references pane),
// so navigation degrades rather than disappearing.
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
    // Dev `swiftc` runs have no bundle Resources; take any common install. The
    // macOS-stock /usr/bin/ctags is BSD ctags, which rejects the long options
    // below — it's deliberately not in this list, so a machine with only that
    // reads as "no ctags" and falls back to the rg word search.
    for candidate in [
        "/opt/homebrew/bin/ctags",
        "/usr/local/bin/ctags",
    ] where fm.isExecutableFile(atPath: candidate) {
        // Guard against Homebrew shadowing with a symlink to BSD ctags: only a
        // universal-ctags accepts `--version` printing "Universal Ctags".
        if isUniversalCtags(candidate) { return candidate }
    }
    return nil
}

// A one-shot probe: universal-ctags prints "Universal Ctags" from --version;
// BSD/Exuberant variants don't (and BSD ctags errors on the flag). Keeps the
// index from launching a binary whose output it can't parse.
private func isUniversalCtags(_ path: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = ["--version"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
        try process.run()
    } catch {
        return false
    }
    let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    return text.contains("Universal Ctags")
}

final class SymbolIndex {
    static let didUpdate = Notification.Name("dev.kosych.suit.SymbolIndexDidUpdate")

    // Whether a usable ctags binary exists at all — false means the whole
    // feature degrades to the rg fallback. Resolved once (binaries don't come
    // and go mid-session) so every lookup doesn't spawn a probe.
    static let hasCtags: Bool = resolveCtagsExecutable() != nil

    let root: String
    // name → its definitions, only mutated on the main queue (like FileIndex.files).
    private(set) var byName: [String: [SymbolDefinition]] = [:]
    private(set) var isIndexing = false

    // Bumped per rebuild; a superseded background parse drops its result.
    private var generation = 0
    private var refreshDebounce: DispatchWorkItem?
    private static let indexQueue = DispatchQueue(label: "dev.kosych.suit.symbolindex", qos: .utility)

    // MARK: - Shared per-root cache (FileIndex's pattern)

    private static var cache: [String: SymbolIndex] = [:]

    // The index for the project containing `directory` — its git root inside a
    // repo, the directory itself otherwise, matching FileIndex so the two share
    // a root string.
    static func shared(forDirectory directory: String) -> SymbolIndex {
        let root = FileIndex.gitRoot(of: directory) ?? directory
        if let existing = cache[root] { return existing }
        let index = SymbolIndex(root: root)
        cache[root] = index
        return index
    }

    private init(root: String) {
        self.root = root
        // Rebuild whenever this root's file list changes (FSEvents → FileIndex).
        NotificationCenter.default.addObserver(
            self, selector: #selector(fileIndexChanged(_:)),
            name: FileIndex.didUpdate, object: nil
        )
        rebuild()
    }

    @objc private func fileIndexChanged(_ note: Notification) {
        guard let index = note.object as? FileIndex, index.root == root else { return }
        // Debounce: a burst of FSEvents (a branch switch, a build) shouldn't
        // launch a ctags pass per event.
        refreshDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuild() }
        refreshDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: - Lookup

    func definitions(for name: String) -> [SymbolDefinition] {
        SymbolIndexCore.definitions(named: name, in: byName)
    }

    // MARK: - Building

    func rebuild() {
        guard Self.hasCtags, let ctagsPath = resolveCtagsExecutable() else {
            byName = [:]
            return
        }
        generation += 1
        let expected = generation
        isIndexing = true
        // Snapshot the file list on the main queue; feed it to ctags on stdin so
        // a monorepo's thousands of paths never hit an argv length limit.
        let files = FileIndex.shared(forDirectory: root).files
        let root = self.root
        Self.indexQueue.async { [weak self] in
            let parsed = Self.runCtags(ctagsPath: ctagsPath, root: root, files: files)
            DispatchQueue.main.async {
                guard let self, self.generation == expected else { return }
                self.byName = parsed
                self.isIndexing = false
                NotificationCenter.default.post(name: Self.didUpdate, object: self)
            }
        }
    }

    // Runs `ctags -f - --fields=+n --sort=no -L -` with the file list on stdin,
    // parses the classic tag output. Only definitions, so tabs/patterns are
    // whatever ctags emits; SymbolIndexCore handles the format.
    private static func runCtags(ctagsPath: String, root: String, files: [String]) -> [String: [SymbolDefinition]] {
        guard !files.isEmpty else { return [:] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ctagsPath)
        process.arguments = [
            "-f", "-",            // tags to stdout
            "--fields=+n",        // include line:N
            "--sort=no",          // don't pay to sort; we group by name ourselves
            "-L", "-",            // read the file list from stdin
        ]
        process.currentDirectoryURL = URL(fileURLWithPath: root)

        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return [:]
        }

        // Write the newline-joined file list, then close so ctags sees EOF. Done
        // on a separate queue so a large list can't deadlock against a full
        // stdout pipe we haven't drained yet.
        let listData = Data((files.joined(separator: "\n") + "\n").utf8)
        DispatchQueue.global(qos: .utility).async {
            stdin.fileHandleForWriting.write(listData)
            try? stdin.fileHandleForWriting.close()
        }

        let outData = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        let text = String(decoding: outData, as: UTF8.self)
        return SymbolIndexCore.parseTags(text)
    }
}
