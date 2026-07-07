import Cocoa

// Git awareness (ROADMAP Phase 5): one status monitor per repo root, refreshed
// whenever that root's FileIndex rescans (FSEvents already drives those), so
// the file browser's modified/added badges and the viewer's changed-line marks
// stay live without any polling of their own.
final class GitStatusMonitor {
    static let didUpdate = Notification.Name("GitStatusMonitorDidUpdate")

    private static var cache: [String: GitStatusMonitor] = [:]

    static func shared(forRoot root: String) -> GitStatusMonitor {
        if let existing = cache[root] {
            return existing
        }
        let monitor = GitStatusMonitor(root: root)
        cache[root] = monitor
        return monitor
    }

    let root: String

    // Relative path → porcelain status letter (M, A, D, R, ?), and every
    // directory (relative path) with a changed descendant. Main-queue only.
    private(set) var statusByPath: [String: Character] = [:]
    private(set) var changedDirectories: Set<String> = []

    // The same paths split by porcelain column for the Git tab's sections:
    // index letters (staged) and worktree letters (unstaged; untracked lands
    // here as "?"). A path can appear in both. Main-queue only.
    private(set) var stagedByPath: [String: Character] = [:]
    private(set) var unstagedByPath: [String: Character] = [:]

    // Repo shape for the Files-tab footer: the checked-out branch (nil while
    // detached), local branch count, and worktree count. Main-queue only.
    private(set) var currentBranch: String?
    private(set) var branchCount = 0
    private(set) var worktreeCount = 0

    private var gitDirStream: FSEventStreamRef?
    private var refreshDebounce: DispatchWorkItem?

    private static let queue = DispatchQueue(label: "dev.kosych.suit.gitstatus", qos: .utility)

    private init(root: String) {
        self.root = root
        NotificationCenter.default.addObserver(
            self, selector: #selector(indexUpdated(_:)),
            name: FileIndex.didUpdate, object: nil
        )
        refresh()
        startWatchingGitDir()
    }

    @objc private func indexUpdated(_ note: Notification) {
        guard let index = note.object as? FileIndex, index.root == root else { return }
        refresh()
    }

    func refresh() {
        let root = self.root
        Self.queue.async { [weak self] in
            let parsed = Self.readStatus(root: root)
            let shape = Self.readRepoShape(root: root)
            DispatchQueue.main.async {
                guard let self else { return }
                self.statusByPath = parsed.combined
                self.stagedByPath = parsed.staged
                self.unstagedByPath = parsed.unstaged
                self.currentBranch = shape.branch
                self.branchCount = shape.branches
                self.worktreeCount = shape.worktrees
                var directories: Set<String> = []
                for path in parsed.combined.keys {
                    var dir = (path as NSString).deletingLastPathComponent
                    while !dir.isEmpty {
                        directories.insert(dir)
                        dir = (dir as NSString).deletingLastPathComponent
                    }
                }
                self.changedDirectories = directories
                NotificationCenter.default.post(name: Self.didUpdate, object: self)
            }
        }
    }

    struct StatusSnapshot {
        var combined: [String: Character] = [:]
        var staged: [String: Character] = [:]
        var unstaged: [String: Character] = [:]
    }

    // `git status --porcelain -z`: "XY path\0" entries, renames followed by
    // "\0origpath". The combined letter (browser badges) is the worktree
    // column when it says anything, else the index column — one letter per
    // path is plenty for a badge. The Git tab wants the columns kept apart,
    // so both are also recorded separately.
    private static func readStatus(root: String) -> StatusSnapshot {
        guard let output = runProcess("/usr/bin/git", ["-C", root, "status", "--porcelain", "-z"]) else {
            return StatusSnapshot()
        }
        var snapshot = StatusSnapshot()
        var entries = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        while !entries.isEmpty {
            let entry = entries.removeFirst()
            guard entry.count > 3 else { continue }
            let x = entry[entry.startIndex]
            let y = entry[entry.index(after: entry.startIndex)]
            let path = String(entry.dropFirst(3))
            var letter = y != " " ? y : x
            if x == "?" { letter = "?" }
            if x == "R" || y == "R" {
                letter = "R"
                // The rename's original path rides in the next entry; drop it.
                if !entries.isEmpty { entries.removeFirst() }
            }
            snapshot.combined[path] = letter
            if x == "?" {
                snapshot.unstaged[path] = "?"
            } else {
                if x != " " { snapshot.staged[path] = x }
                if y != " " { snapshot.unstaged[path] = y }
            }
        }
        return snapshot
    }

    // symbolic-ref rather than rev-parse --abbrev-ref so a freshly-initialized
    // repo (no commits yet) still reports its branch; -q makes a detached HEAD
    // a quiet nil. for-each-ref and `worktree list --porcelain` are plumbing,
    // so their output is stable to count lines of.
    private static func readRepoShape(root: String) -> (branch: String?, branches: Int, worktrees: Int) {
        let branch = runProcess("/usr/bin/git", ["-C", root, "symbolic-ref", "--short", "-q", "HEAD"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let branches = runProcess("/usr/bin/git", ["-C", root, "for-each-ref", "--format=%(refname)", "refs/heads"])
            .map { $0.split(separator: "\n", omittingEmptySubsequences: true).count } ?? 0
        let worktrees = runProcess("/usr/bin/git", ["-C", root, "worktree", "list", "--porcelain"])
            .map { output in
                output.split(separator: "\n", omittingEmptySubsequences: true)
                    .filter { $0.hasPrefix("worktree ") }.count
            } ?? 0
        return (branch?.isEmpty == false ? branch : nil, branches, worktrees)
    }

    // FileIndex deliberately ignores FSEvents under .git (see handleEvents
    // there), so ref-only operations — commit, branch, checkout, worktree
    // add/remove — would never reach refresh() through the index. Watch the
    // common git dir (covers linked worktrees' HEADs too) for exactly those.
    private func startWatchingGitDir() {
        let root = self.root
        Self.queue.async { [weak self] in
            guard let output = runProcess("/usr/bin/git", ["-C", root, "rev-parse", "--git-common-dir"]) else { return }
            var gitDir = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !gitDir.isEmpty else { return }
            if !gitDir.hasPrefix("/") {
                gitDir = root + "/" + gitDir
            }
            DispatchQueue.main.async { self?.watchGitDir(at: gitDir) }
        }
    }

    private func watchGitDir(at gitDir: String) {
        guard gitDirStream == nil else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, eventCount, eventPaths, _, _ in
            guard let info else { return }
            let monitor = Unmanaged<GitStatusMonitor>.fromOpaque(info).takeUnretainedValue()
            guard let paths = unsafeBitCast(eventPaths, to: CFArray.self) as? [String] else { return }
            monitor.handleGitDirEvents(paths: Array(paths.prefix(eventCount)))
        }
        // FileEvents so paths name the touched files, not just ".git" — the
        // filter below needs to tell a HEAD move from an index write.
        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [gitDir] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        ) else { return }
        gitDirStream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    // Only ref-shaped paths trigger a refresh: HEAD moves, branch refs,
    // packed-refs rewrites, worktree registrations. Everything else —
    // .git/index above all — is ignored, because refresh()'s own `git status`
    // may rewrite the index, and refreshing on that would chase our tail.
    private func handleGitDirEvents(paths: [String]) {
        let relevant = paths.contains { path in
            path.hasSuffix("/HEAD") || path.contains("/refs/")
                || path.hasSuffix("/packed-refs") || path.contains("/worktrees/")
        }
        guard relevant else { return }
        refreshDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    static func badgeColor(for letter: Character) -> NSColor {
        switch letter {
        case "A", "?": return Theme.sessionDone
        case "D": return Theme.failed
        default: return Theme.sessionBusy
        }
    }
}

// The viewer's changed-region source: the new-file line ranges of `git diff
// HEAD -U0 -- file`, parsed off the main thread.
enum GitChangedLines {
    static func compute(filePath: String, completion: @escaping (IndexSet) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let directory = (filePath as NSString).deletingLastPathComponent
            guard let root = FileIndex.gitRoot(of: directory),
                  let diff = runProcess("/usr/bin/git", ["-C", root, "diff", "HEAD", "-U0", "--", filePath]) else {
                DispatchQueue.main.async { completion(IndexSet()) }
                return
            }
            var lines = IndexSet()
            diff.enumerateLines { raw, _ in
                // @@ -a,b +c,d @@ — the +c,d side is where the file's current
                // content changed; d==0 (pure deletion) still marks line c so
                // the removal site is findable.
                guard raw.hasPrefix("@@") else { return }
                let parts = raw.split(separator: " ")
                guard parts.count >= 3, parts[2].hasPrefix("+") else { return }
                let plus = parts[2].dropFirst().split(separator: ",")
                guard let start = Int(plus.first ?? "") else { return }
                let count = plus.count > 1 ? (Int(plus[1]) ?? 1) : 1
                if count == 0 {
                    lines.insert(max(1, start))
                } else {
                    lines.insert(integersIn: start..<(start + count))
                }
            }
            DispatchQueue.main.async { completion(lines) }
        }
    }
}
