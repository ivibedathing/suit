import Foundation

// The in-memory file list behind the fuzzy opener (Cmd-P) and the Files
// sidebar: every non-ignored file under one project root, kept fresh by
// FSEvents. Indexes are cached per root and live for the app's lifetime, so
// every window (and later feature) looking at the same project shares one
// list and one watcher.
final class FileIndex {
    static let didUpdate = Notification.Name("dev.kosych.suit.FileIndexDidUpdate")

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
    // normalization — for the sidebar's pinned folder (ROADMAP Phase 9), where
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
        let output = runProcess("/usr/bin/git", ["-C", directory, "rev-parse", "--show-toplevel"])
        guard let output, !output.isEmpty else { return nil }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private init(root: String) {
        self.root = root
        rescan()
        startWatching()
    }

    // MARK: - Scanning

    func rescan() {
        isScanning = true
        Self.scanQueue.async { [weak self] in
            guard let self else { return }
            let scanned = Self.scan(root: self.root)
            DispatchQueue.main.async {
                self.files = scanned
                self.subprojectBadges = Self.detectSubprojects(in: scanned)
                self.isScanning = false
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

    // Outside a git repo there's no ignore file to honor, so filter the usual
    // machine-generated trees and hidden files, and cap the walk so pointing a
    // window at ~/ doesn't try to index the world.
    private static let fallbackExcludedDirectories: Set<String> = [
        "node_modules", "build", ".build", "dist", "target", "DerivedData", "Library",
    ]
    private static let fileCap = 50_000

    private static func fallbackScan(root: String) -> [String] {
        let rootURL = URL(fileURLWithPath: root)
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        var result: [String] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values?.isDirectory == true {
                if fallbackExcludedDirectories.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true, url.path.hasPrefix(rootPrefix) else { continue }
            result.append(String(url.path.dropFirst(rootPrefix.count)))
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
        let gitDir = root + "/.git"
        let relevant = paths.contains { !$0.hasPrefix(gitDir) }
        guard relevant else { return }

        rescanDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rescan() }
        rescanDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}

// Runs a process to completion and returns stdout, or nil on nonzero exit /
// launch failure. Used for git (here, the diff pane, Phase 5 review tooling);
// never called on paths derived from file content.
func runProcess(_ executable: String, _ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = Pipe()
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
