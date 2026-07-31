import Foundation

// The in-memory file list behind the fuzzy opener (Cmd-P) and the Files
// sidebar: every non-ignored file under one project root, kept fresh by
// FSEvents. Indexes are cached per root and live for the app's lifetime, so
// every window (and later feature) looking at the same project shares one
// list and one watcher.
final class FileIndex {
    static let didUpdate = Notification.Name("dev.kosych.suit.FileIndexDidUpdate")
    // Posted after every completed scan, whether or not the file list moved —
    // see the two-signal note in rescan(). Observers that care about file
    // *contents* rather than the set of paths (the git status monitor) want
    // this one; everything else wants didUpdate.
    static let didScan = Notification.Name("dev.kosych.suit.FileIndexDidScan")

    // Marker file → badge shown on that directory in the Files sidebar. What
    // makes the browser "multi-project-aware": sub-project roots read as projects,
    // not just folders.
    static let subprojectMarkers: [String: String] = [
        "go.mod": "go",
        "package.json": "js",
        "Package.swift": "swift",
        "Cargo.toml": "rust",
        "pyproject.toml": "py",
    ]

    let root: String

    // Sorted root-relative paths, and the sub-project badge for each directory
    // (relative path) that contains a marker file. Both only mutate on the
    // main queue; reads from the main queue (palette, sidebar) are safe.
    private(set) var files: [String] = []
    private(set) var subprojectBadges: [String: String] = [:]
    private(set) var isScanning = false

    // The gitignored rows, kept *out* of `files` on purpose: the Files tree
    // draws them greyed, while ⌘P and project search stay ignore-clean.
    private(set) var ignored: [IgnoredEntry] = []

    // Absolute paths of the ignored *directories* above, without a trailing
    // slash — the FSEvents filter's lookup table, rebuilt whenever a scan lands
    // so the event handler never has to touch git or the filesystem to decide.
    private var ignoredDirectoryPrefixes: [String] = []

    // One ignored row. Collapsed at the shallowest ignored directory (see
    // scanIgnored), so `node_modules/` is a single entry rather than the
    // 30,000 paths beneath it; FileBrowserView fills a collapsed directory in
    // from disk only if the user actually expands it.
    struct IgnoredEntry: Hashable {
        let path: String          // root-relative, no trailing slash
        let isDirectory: Bool
    }

    private var eventStream: FSEventStreamRef?
    private var rescanDebounce: DispatchWorkItem?
    private static let scanQueue = DispatchQueue(label: "dev.kosych.suit.fileindex", qos: .userInitiated)

    // MARK: - Shared per-root cache

    private static var cache: [String: FileIndex] = [:]

    // The index for the project containing `directory`: its git root when
    // inside a repo, the directory itself otherwise.
    static func shared(forDirectory directory: String) -> FileIndex {
        let root = gitRoot(of: directory) ?? directory
        if let existing = cache[root] {
            return existing
        }
        let index = FileIndex(root: root)
        cache[root] = index
        return index
    }

    // An index rooted exactly at `directory`, skipping the git-root
    // normalization — for the sidebar's pinned folder, where
    // the picked folder itself is the root even inside a repo. `git ls-files`
    // run from a subdirectory returns subdirectory-relative paths, so
    // .gitignore semantics stay exact.
    static func shared(forExactDirectory directory: String) -> FileIndex {
        if let existing = cache[directory] {
            return existing
        }
        let index = FileIndex(root: directory)
        cache[directory] = index
        return index
    }

    static func gitRoot(of directory: String) -> String? {
        // A probe: "not a repo" is an ordinary answer here, not a failure.
        let output = runProcess(
            "/usr/bin/git", ["-C", directory, "rev-parse", "--show-toplevel"], probe: true
        )
        guard let output, !output.isEmpty else { return nil }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private init(root: String) {
        self.root = root
        rescan(trigger: "project opened")
        startWatching()
    }

    // MARK: - Scanning

    // `trigger` is what the operations log reports as the cause, and it is
    // scoped around the scan so the two `git ls-files` calls underneath inherit
    // it too — the Background tab then shows the scan and the git work it did
    // as one attributable group rather than three unexplained rows.
    func rescan(trigger: String = "manual") {
        isScanning = true
        Self.scanQueue.async { [weak self] in
            guard let self else { return }
            let watch = OpsStopwatch()
            let (scanned, ignored) = OpsLog.withTrigger(trigger) {
                (Self.scan(root: self.root), Self.scanIgnored(root: self.root))
            }
            OpsLog.shared.record(
                kind: .index, label: "index scan",
                detail: "\(scanned.count) files · \((self.root as NSString).lastPathComponent)",
                trigger: trigger,
                startedAt: watch.startedAt, duration: watch.elapsed,
                outcome: scanned.isEmpty ? .empty : .ok
            )
            DispatchQueue.main.async {
                let unchanged = scanned == self.files && ignored == self.ignored
                self.files = scanned
                self.ignored = ignored
                self.ignoredDirectoryPrefixes = ignored
                    .filter { $0.isDirectory }
                    .map { self.root + "/" + $0.path }
                self.subprojectBadges = Self.detectSubprojects(in: scanned)
                self.isScanning = false
                // Two signals, because two kinds of observer want two different
                // questions answered:
                //
                //   didScan   — a scan finished. Always posted. Editing a file
                //               git already tracks changes no path here, but it
                //               absolutely changes `git status`, so the status
                //               monitor has to hear about it. (Suppressing this
                //               is what stopped Source Control noticing
                //               ordinary edits.)
                //   didUpdate — the file list itself changed. The Files tree,
                //               the symbol index and ⌘P rebuild from it, and a
                //               rescan that found the same paths gives them
                //               nothing to do.
                //
                // The first scan posts both: `files` starts empty, so any real
                // project differs from it.
                NotificationCenter.default.post(name: Self.didScan, object: self)
                guard !unchanged else { return }
                NotificationCenter.default.post(name: Self.didUpdate, object: self)
            }
        }
    }

    private static func scan(root: String) -> [String] {
        // `git ls-files` is both faster than walking the tree ourselves and the
        // only correct .gitignore implementation there is. --cached + --others
        // (with the standard excludes) is exactly "tracked plus untracked but
        // not ignored".
        if let output = runProcess("/usr/bin/git", ["-C", root, "ls-files", "--cached", "--others", "--exclude-standard", "-z"]) {
            var seen = Set<String>()
            var result: [String] = []
            for path in output.split(separator: "\0") where !path.isEmpty {
                let path = String(path)
                if seen.insert(path).inserted {
                    result.append(path)
                }
            }
            return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }
        return fallbackScan(root: root)
    }

    // The ignored counterpart of scan()'s --others: same walk, opposite side of
    // .gitignore. --directory is what makes it affordable — git reports a
    // wholly-ignored directory as one entry (`build/`) instead of every file
    // under it, so pointing the browser at a repo with a fat node_modules
    // costs one row, not thirty thousand. Empty outside a repo: with no
    // .gitignore to read, nothing is ignored (the fallback scan's pruning of
    // node_modules/.git is a different thing, and stays hidden).
    private static func scanIgnored(root: String) -> [IgnoredEntry] {
        guard let output = runProcess("/usr/bin/git", [
            "-C", root, "ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z",
        ]) else { return [] }
        return parseIgnoredEntries(output)
    }

    // Split from the git call so a harness can assert the parse: NUL-separated
    // entries, a trailing slash marks a directory, and the result is sorted
    // parents-first so the tree builder always meets `build/` before anything
    // that lands beneath it.
    static func parseIgnoredEntries(_ output: String) -> [IgnoredEntry] {
        var seen = Set<String>()
        var result: [IgnoredEntry] = []
        for raw in output.split(separator: "\0") where !raw.isEmpty {
            let text = String(raw)
            let isDirectory = text.hasSuffix("/")
            let path = isDirectory ? String(text.dropLast()) : text
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            result.append(IgnoredEntry(path: path, isDirectory: isDirectory))
        }
        return result.sorted { $0.path < $1.path }
    }

    // One level of a collapsed ignored directory, read straight off disk:
    // everything inside an ignored tree is ignored too, so there is nothing
    // left to ask git. Capped because an expanded node_modules is enormous and
    // nobody scrolls 20,000 rows.
    static func ignoredChildren(ofDirectory relativePath: String, root: String) -> [IgnoredEntry] {
        let directory = root + "/" + relativePath
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        var result: [IgnoredEntry] = []
        for name in names.sorted().prefix(ignoredChildCap) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory + "/" + name, isDirectory: &isDirectory) else {
                continue
            }
            result.append(IgnoredEntry(path: relativePath + "/" + name, isDirectory: isDirectory.boolValue))
        }
        return result
    }

    private static let ignoredChildCap = 2_000

    // Outside a git repo there's no ignore file to honor, so filter the usual
    // machine-generated trees by name, and cap the walk so pointing a window at
    // ~/ doesn't try to index the world.
    //
    // Dot-directories are *not* filtered wholesale: `.claude`, `.github`,
    // `.config` are content the sidebar has to show, and inside a repo
    // `git ls-files` reports them, so skipping them here made the same folder
    // appear or vanish depending on whether the root happened to be a git
    // checkout. Only the known-noisy hidden trees below are pruned.
    static let fallbackExcludedDirectories: Set<String> = [
        "node_modules", "build", ".build", "dist", "target", "DerivedData", "Library",
        ".git", ".hg", ".svn", ".Trash", ".Spotlight-V100", ".fseventsd", ".TemporaryItems",
    ]
    // Finder/AppleDouble droppings — never worth a row.
    private static func isFallbackNoiseFile(_ name: String) -> Bool {
        name == ".DS_Store" || name == ".localized" || name.hasPrefix("._")
    }
    private static let fileCap = 50_000

    static func fallbackScan(root: String) -> [String] {
        let rootURL = URL(fileURLWithPath: root)
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else { return [] }

        // The enumerator hands back symlink-resolved paths (a root under /tmp or
        // /var comes back as /private/…), so matching only the literal root
        // prefix silently dropped every file under a symlinked root. Accept
        // either spelling.
        // realpath, not URL.resolvingSymlinksInPath — the latter strips a
        // leading /private and leaves /var/folders alone, which is exactly the
        // spelling that needs resolving here.
        var prefixes = [rootURL.path]
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if let resolved = realpath(rootURL.path, &buffer).map({ String(cString: $0) }),
           resolved != rootURL.path {
            prefixes.append(resolved)
        }
        prefixes = prefixes.map { $0.hasSuffix("/") ? $0 : $0 + "/" }

        var result: [String] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values?.isDirectory == true {
                if fallbackExcludedDirectories.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true, !isFallbackNoiseFile(url.lastPathComponent),
                  let prefix = prefixes.first(where: { url.path.hasPrefix($0) }) else { continue }
            result.append(String(url.path.dropFirst(prefix.count)))
            if result.count >= fileCap {
                break
            }
        }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private static func detectSubprojects(in files: [String]) -> [String: String] {
        var badges: [String: String] = [:]
        for path in files {
            let name = (path as NSString).lastPathComponent
            guard let badge = subprojectMarkers[name] else { continue }
            let directory = (path as NSString).deletingLastPathComponent
            // First marker wins; markers deeper in vendored trees still badge
            // their own directory, which is what a multi-project section list wants.
            if badges[directory] == nil {
                badges[directory] = badge
            }
        }
        return badges
    }

    // MARK: - FSEvents

    private func startWatching() {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        // UseCFTypes makes eventPaths a CFArray of CFStrings; without it the
        // callback gets a raw char** and this cast would read garbage.
        let callback: FSEventStreamCallback = { _, info, eventCount, eventPaths, _, _ in
            guard let info else { return }
            let index = Unmanaged<FileIndex>.fromOpaque(info).takeUnretainedValue()
            guard let paths = unsafeBitCast(eventPaths, to: CFArray.self) as? [String] else { return }
            index.handleEvents(paths: Array(paths.prefix(eventCount)))
        }
        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [root] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        ) else { return }
        eventStream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    private func handleEvents(paths: [String]) {
        // Every git command rewrites something under .git; rescanning on those
        // would make the index thrash during normal git use. Only .git-internal
        // events are skipped — a checkout that changes the worktree also
        // reports the changed worktree directories, which do trigger a rescan.
        //
        // Ignored trees are skipped for the same reason and it matters more:
        // `build/`, `node_modules/`, and `.claude/worktrees/` (whole checkouts
        // other agents are actively building in) generate near-continuous
        // events, and not one of them can change what `git ls-files` returns.
        // Left unfiltered they kept a full rescan — and everything downstream
        // of didUpdate — running for as long as anything was compiling.
        let relevant = paths.contains { !isIgnoredEventPath($0) }
        guard relevant else { return }

        rescanDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rescan(trigger: "file change") }
        rescanDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    // Whether an FSEvents path is one a rescan could not possibly learn from:
    // inside .git, or inside a directory git already reported as ignored.
    //
    // `ignoredDirectoryPrefixes` is rebuilt from the last scan's collapsed
    // ignored entries, which is why a *newly* created ignored directory still
    // costs one rescan — it isn't known to be ignored until a scan says so.
    // That is the correct trade: one rescan to learn it, silence afterwards.
    //
    // The stream is created without kFSEventStreamCreateFlagFileEvents, so what
    // arrives are *directory* paths — "…/build", not "…/build/obj1.o", and with
    // no consistent trailing slash. Matching has to accept the directory itself
    // as well as anything under it; a plain hasPrefix on a slash-terminated
    // string silently matches nothing.
    private func isIgnoredEventPath(_ path: String) -> Bool {
        let normalized = path.hasSuffix("/") ? String(path.dropLast()) : path
        if normalized == root + "/.git" || normalized.hasPrefix(root + "/.git/") { return true }
        return ignoredDirectoryPrefixes.contains {
            normalized == $0 || normalized.hasPrefix($0 + "/")
        }
    }
}

// Runs a process to completion and returns stdout, or nil on nonzero exit /
// launch failure. Used for git (here, the diff pane, review tooling);
// never called on paths derived from file content.
//
// Every internal subprocess Suit spawns of its own accord goes through here,
// which makes this the one place worth instrumenting: the operations log
// (OpsLog) derives the row's name and kind from argv, so a `git` call added
// anywhere in the app shows up in the Background tab without its author writing
// a line of logging. `trigger` names *why* the call is being made — pass it at
// sites that know (the status monitor knows an FSEvents burst asked); anything
// else inherits the ambient trigger its caller scoped with OpsLog.withTrigger.
// `probe` marks a call whose *job* is to ask a yes/no question — "is this
// directory in a repo", "does this ref exist" — where a nonzero exit is the
// answer "no", not a fault. Without it those rows log red, and a log where the
// commonest routine call is red is a log whose red stops meaning anything.
func runProcess(
    _ executable: String, _ arguments: [String], trigger: String? = nil, probe: Bool = false
) -> String? {
    let derived = OpsLabel.derive(executable: executable, arguments: arguments)
    let watch = OpsStopwatch()
    let output = spawnProcess(executable, arguments)
    OpsLog.shared.record(
        kind: derived.kind,
        label: derived.label,
        detail: derived.detail,
        trigger: trigger ?? OpsLog.currentTrigger,
        startedAt: watch.startedAt,
        duration: watch.elapsed,
        // A command that ran fine and printed nothing (`git status` in a clean
        // tree) is `.empty`, not a failure.
        outcome: output.map { $0.isEmpty ? .empty : .ok } ?? (probe ? .empty : .failed)
    )
    return output
}

// The uninstrumented spawn. Split out so the timing wrapper above reads as one
// thing and the process plumbing as another.
private func spawnProcess(_ executable: String, _ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let stdout = Pipe()
    process.standardOutput = stdout
    // stderr is discarded (we only return stdout), but it must be drained or the
    // child blocks once it writes past the ~64 KB pipe buffer — with stderr's
    // pipe never read, that stalls the child, which never closes stdout, so the
    // readDataToEndOfFile below would hang forever. Route it to /dev/null so a
    // chatty git command (a flood of warnings, advice, CRLF notices) can't wedge us.
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return nil
    }
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)
}
