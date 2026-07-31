import Foundation
import Dispatch

// The operations log: what Suit itself does when nobody asked it to.
//
// Suit runs a great deal of work off its own initiative — a `git status` per
// FSEvents burst, `gh pr list` when the Source Control tab comes forward, a
// `git ls-files` rescan, a ctags pass, an update check. All of it is invisible
// until it goes wrong, and when it went wrong (the FSEvents→git→gh cascade that
// made the window drop frames) the only way to see it was to attach a profiler
// or read the code. This is the surface that makes it observable: every
// internal task, with what triggered it, how long it took, and whether it
// worked. The sidebar's Background tab (OpsLogView) renders it.
//
// This file is the UI-free, standalone-compilable core (the RoadmapParser /
// FeedbackRouting / Activity pattern — Foundation-only, no AppKit and no app
// deps), so `scripts/ops-log-test.sh` compiles it alone and asserts the argv→
// label derivation, the ring buffer's bound, adjacent-run collapsing, the
// rolling window stats and the formatters without spinning any UI.
//
// Deliberately **not** persisted, unlike ~/.suit/activity.jsonl. Activity rows
// are rare and notable (a PR merged); these are high-frequency and mundane —
// appending every `git status` to a file would recreate, in the logger, exactly
// the disk churn the log exists to expose. It is an in-memory ring: the last
// `capacity` operations, gone at quit.

// MARK: - Kinds

// What subsystem the operation belongs to — the row glyph, its tint, and the
// tab's filter menu. rawValue is the stable identifier (used by the filter's
// persisted selection), so kinds can be added without disturbing the others.
enum OpsKind: String, CaseIterable {
    case git
    case gh
    case search
    case index
    case symbols
    case network
    case autopilot
    case process

    var label: String {
        switch self {
        case .git: return "Git"
        case .gh: return "GitHub"
        case .search: return "Search"
        case .index: return "File index"
        case .symbols: return "Symbols"
        case .network: return "Network"
        case .autopilot: return "Autopilot"
        case .process: return "Process"
        }
    }

    // SF Symbol name. Kept a plain string so the core stays Foundation-only;
    // the view resolves it to an NSImage (the ActivityKind.glyph pattern).
    var glyph: String {
        switch self {
        case .git: return "arrow.triangle.branch"
        case .gh: return "chevron.left.forwardslash.chevron.right"
        case .search: return "magnifyingglass"
        case .index: return "folder"
        case .symbols: return "curlybraces"
        case .network: return "antenna.radiowaves.left.and.right"
        case .autopilot: return "sparkles"
        case .process: return "terminal"
        }
    }
}

// Whether the operation did what it set out to. `.empty` is the third state
// that matters in practice: a command that ran fine and found nothing (rg with
// no matches, a `git rev-parse` outside a repo) is not a failure, but it is
// also not the same as work done — and reading a log where half the rows are
// red for "no matches" trains you to ignore the red ones.
enum OpsOutcome: String {
    case ok
    case empty
    case failed

    var isFailed: Bool { self == .failed }
}

// MARK: - Record

// One completed operation. `seq` is assigned by the log and only ever
// increases, which is what makes rows stably identifiable across refreshes
// without a timestamp collision (several git calls in one millisecond is
// ordinary).
struct OpsRecord: Equatable {
    var seq: UInt64
    var kind: OpsKind
    // What ran, in the shortest form that still says it: "git status",
    // "gh pr list", "index scan".
    var label: String
    // Where or on what — a repo name, a pattern, a file count.
    var detail: String?
    // Why it ran: "file change", "tab shown", "launch", "user". nil when the
    // call site hasn't been annotated, which reads as "unattributed" rather
    // than claiming a cause the log doesn't know.
    var trigger: String?
    var startedAt: TimeInterval   // epoch seconds
    var duration: TimeInterval
    var outcome: OpsOutcome
}

// MARK: - argv → label

// Turning a spawn into a row. Every internal subprocess funnels through
// runProcess (and GitBranches' gh runner), so deriving the label from argv is
// what lets one wrapper instrument dozens of call sites — no per-site strings
// to write, and a new `git` call added anywhere shows up in the log for free.
enum OpsLabel {
    // git subcommands whose useful name is two words: `git worktree list` is
    // worth distinguishing from `git worktree add`, while `git status` needs
    // nothing after it.
    private static let twoWordGitSubcommands: Set<String> = [
        "worktree", "stash", "remote", "submodule", "notes", "bisect", "reflog", "sparse-checkout",
    ]

    // git's own options that swallow the following argument — the ones Suit
    // actually passes. Skipping them is what keeps `-C <path>` from being read
    // as the subcommand.
    private static let gitValueOptions: Set<String> = ["-C", "-c", "--git-dir", "--work-tree"]

    struct Derived: Equatable {
        var kind: OpsKind
        var label: String
        var detail: String?
    }

    static func derive(executable: String, arguments: [String]) -> Derived {
        let name = (executable as NSString).lastPathComponent
        switch name {
        case "git":
            return deriveGit(arguments)
        case "gh":
            return Derived(kind: .gh, label: joined("gh", firstTokens(arguments, count: 2)), detail: nil)
        case "rg", "ripgrep":
            return Derived(kind: .search, label: "ripgrep", detail: value(after: "--regexp", in: arguments))
        case "ctags", "uctags":
            // The file list arrives on stdin (`-L -`), so argv says nothing
            // about scope; the caller supplies that as an explicit detail.
            return Derived(kind: .symbols, label: "ctags", detail: nil)
        case "lsof":
            return Derived(kind: .process, label: "lsof", detail: value(after: "-p", in: arguments))
        case "zsh", "bash", "sh":
            // A login shell used to resolve something (`command -v gh`); the
            // command string is the only interesting part.
            return Derived(kind: .process, label: "shell", detail: value(after: "-c", in: arguments))
        default:
            return Derived(kind: .process, label: name, detail: firstTokens(arguments, count: 1).first)
        }
    }

    private static func deriveGit(_ arguments: [String]) -> Derived {
        var repo: String?
        var subcommand: String?
        var following: String?
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let token = arguments[index]
            if gitValueOptions.contains(token) {
                let valueIndex = arguments.index(after: index)
                if valueIndex < arguments.endIndex {
                    if token == "-C" { repo = (arguments[valueIndex] as NSString).lastPathComponent }
                    index = arguments.index(after: valueIndex)
                    continue
                }
                break
            }
            if token.hasPrefix("-") {
                index = arguments.index(after: index)
                continue
            }
            if subcommand == nil {
                subcommand = token
                // Only a two-word subcommand consumes what follows; otherwise
                // the next token is a ref or a path, not part of the name.
                if !twoWordGitSubcommands.contains(token) { break }
            } else {
                following = token
                break
            }
            index = arguments.index(after: index)
        }

        var label = "git"
        if let subcommand { label += " " + subcommand }
        if let following { label += " " + following }
        return Derived(kind: .git, label: label, detail: repo)
    }

    // The first `count` tokens that aren't flags — how a `gh pr list --json …`
    // becomes "gh pr list".
    private static func firstTokens(_ arguments: [String], count: Int) -> [String] {
        var result: [String] = []
        for token in arguments where !token.hasPrefix("-") {
            result.append(token)
            if result.count == count { break }
        }
        return result
    }

    private static func joined(_ head: String, _ tokens: [String]) -> String {
        ([head] + tokens).joined(separator: " ")
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let position = arguments.firstIndex(of: flag) else { return nil }
        let next = arguments.index(after: position)
        guard next < arguments.endIndex else { return nil }
        return arguments[next]
    }
}

// MARK: - Formatting

enum OpsFormat {
    // Durations, at the precision that tells you something: sub-second work is
    // whole milliseconds (the difference between 8ms and 120ms is the whole
    // story), anything longer rounds to a tenth of a second.
    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 0 { return "—" }
        let milliseconds = seconds * 1000
        if milliseconds < 1 { return "<1ms" }
        if milliseconds < 1000 { return "\(Int(milliseconds.rounded()))ms" }
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let minutes = Int(seconds) / 60
        let remainder = Int(seconds) % 60
        return String(format: "%dm %02ds", minutes, remainder)
    }

    // How long ago, in one or two characters plus a unit — the rows are narrow
    // and the exact second stopped mattering the moment it scrolled.
    static func age(_ seconds: TimeInterval) -> String {
        let value = max(0, seconds)
        if value < 60 { return "\(Int(value))s" }
        if value < 3600 { return "\(Int(value) / 60)m" }
        if value < 86_400 { return "\(Int(value) / 3600)h" }
        return "\(Int(value) / 86_400)d"
    }
}

// MARK: - Collapsing

// A rendered row: one record, plus how many identical ones it stands for.
// Adjacent identical operations are the normal case here — a burst of FSEvents
// yields six `git status` runs in a row, and six near-identical rows push
// everything else off screen while saying nothing the count doesn't.
struct OpsRow: Equatable {
    var record: OpsRecord     // the newest of the run
    var count: Int
    var totalDuration: TimeInterval

    var isCollapsed: Bool { count > 1 }
}

enum OpsCollapse {
    // Newest-first rows, merging *adjacent* runs of the same operation. Only
    // adjacent ones: collapsing across the whole buffer would hide the fact
    // that a command re-ran after something else happened, which is exactly
    // the interleaving a cascade shows up as.
    static func rows(_ records: [OpsRecord], limit: Int = .max) -> [OpsRow] {
        var rows: [OpsRow] = []
        for record in records.sorted(by: { $0.seq > $1.seq }) {
            if var last = rows.last, matches(last.record, record) {
                last.count += 1
                last.totalDuration += record.duration
                rows[rows.count - 1] = last
                continue
            }
            if rows.count >= limit { break }
            rows.append(OpsRow(record: record, count: 1, totalDuration: record.duration))
        }
        return rows
    }

    // Same operation for collapsing purposes. Outcome is part of it: a failure
    // in the middle of a run of successes is the row you came to find.
    private static func matches(_ a: OpsRecord, _ b: OpsRecord) -> Bool {
        a.kind == b.kind && a.label == b.label && a.detail == b.detail
            && a.trigger == b.trigger && a.outcome == b.outcome
    }
}

// MARK: - Filtering & stats

enum OpsFilter {
    // kind nil = any. `query` matches the label, detail or trigger, case-
    // insensitively; empty or whitespace-only means no text filter.
    static func apply(_ records: [OpsRecord], kind: OpsKind? = nil, query: String? = nil) -> [OpsRecord] {
        let needle = query?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        return records.filter { record in
            if let kind, record.kind != kind { return false }
            guard !needle.isEmpty else { return true }
            let haystack = [record.label, record.detail ?? "", record.trigger ?? ""]
                .joined(separator: " ").lowercased()
            return haystack.contains(needle)
        }
    }

    // The kinds actually present, in declaration order — the filter menu shows
    // only what the log has seen, so it never offers an empty selection.
    static func kinds(in records: [OpsRecord]) -> [OpsKind] {
        let present = Set(records.map { $0.kind })
        return OpsKind.allCases.filter { present.contains($0) }
    }
}

// The footer line: how much work the app did in the last stretch. This is the
// number that would have made the FSEvents→git cascade obvious — "47 runs ·
// 2.3s in the last minute" while the user typed in a file is self-evidently
// wrong in a way that no single row is.
struct OpsRollup: Equatable {
    var runs: Int
    var failures: Int
    var totalDuration: TimeInterval

    var isEmpty: Bool { runs == 0 }

    // Records started within `window` seconds of `now`. Half-open on the old
    // side so a record exactly at the boundary counts, which keeps a harness
    // with fabricated round timestamps from testing floating-point luck.
    static func over(_ records: [OpsRecord], now: TimeInterval, window: TimeInterval) -> OpsRollup {
        var rollup = OpsRollup(runs: 0, failures: 0, totalDuration: 0)
        for record in records where record.startedAt >= now - window && record.startedAt <= now {
            rollup.runs += 1
            rollup.totalDuration += record.duration
            if record.outcome.isFailed { rollup.failures += 1 }
        }
        return rollup
    }

    func summary(window: TimeInterval) -> String {
        guard !isEmpty else { return "idle for \(OpsFormat.age(window))" }
        var text = "\(runs) run\(runs == 1 ? "" : "s") · \(OpsFormat.duration(totalDuration))"
        if failures > 0 { text += " · \(failures) failed" }
        return text + " in \(OpsFormat.age(window))"
    }
}

// MARK: - Stopwatch

// Wall time for the row, monotonic time for the duration. `Date()` alone would
// report a negative duration across a clock adjustment, and these durations are
// the whole point of the log.
struct OpsStopwatch {
    let startedAt: TimeInterval
    private let mark: UInt64

    init() {
        startedAt = Date().timeIntervalSince1970
        mark = DispatchTime.now().uptimeNanoseconds
    }

    var elapsed: TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds &- mark) / 1_000_000_000
    }
}

// MARK: - The log

final class OpsLog {
    static let shared = OpsLog()
    static let didUpdate = Notification.Name("dev.kosych.suit.OpsLogDidUpdate")

    // The ring's size. Deep enough that a burst doesn't erase the context that
    // explains it, small enough to be free: ~800 small structs.
    static let capacity = 800

    // How often the log may wake its observers, at most. Recording happens on
    // whatever queue the work ran on and can arrive in bursts of dozens; a
    // notification per record would make the log itself the storm — the view
    // would rebuild its rows faster than a human can read one. Coalescing here
    // rather than in the view keeps every future observer on the same budget.
    static let notifyInterval: TimeInterval = 0.3

    // Paused means "stop recording", not "stop showing" — the buffer keeps what
    // it has so a snapshot can be read at leisure while the app keeps working.
    //
    // Toggled from the UI on the main queue and read by record() from whatever
    // background queue the work ran on, so it goes through the same lock as the
    // buffer. The accessors take the lock and record() reads `pausedFlag`
    // directly — NSLock isn't recursive, and a computed property called from
    // inside the locked region would deadlock rather than race.
    var isPaused: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return pausedFlag
        }
        set {
            lock.lock()
            pausedFlag = newValue
            lock.unlock()
        }
    }

    private var pausedFlag = false
    private var records: [OpsRecord] = []
    private var nextSeq: UInt64 = 1
    private let lock = NSLock()
    private var notifyScheduled = false

    // Recording is called from background queues (the git status queue, the
    // index scan queue, rg's parse queue); every accessor takes the lock.
    func record(
        kind: OpsKind,
        label: String,
        detail: String? = nil,
        trigger: String? = nil,
        startedAt: TimeInterval,
        duration: TimeInterval,
        outcome: OpsOutcome
    ) {
        lock.lock()
        guard !pausedFlag else {
            lock.unlock()
            return
        }
        records.append(OpsRecord(
            seq: nextSeq, kind: kind, label: label, detail: detail, trigger: trigger,
            startedAt: startedAt, duration: duration, outcome: outcome
        ))
        nextSeq += 1
        if records.count > Self.capacity {
            records.removeFirst(records.count - Self.capacity)
        }
        lock.unlock()
        scheduleNotify()
    }

    // Times `body`, records it, and hands back its value — the shape every
    // instrumented call site uses. `outcome` reads the result rather than being
    // passed in, so a site can't record success for a call that returned nil.
    func measure<T>(
        kind: OpsKind,
        label: String,
        detail: String? = nil,
        trigger: String? = nil,
        outcome: (T) -> OpsOutcome,
        detailForResult: ((T) -> String?)? = nil,
        body: () -> T
    ) -> T {
        let watch = OpsStopwatch()
        let result = body()
        record(
            kind: kind, label: label,
            detail: detailForResult?(result) ?? detail,
            trigger: trigger,
            startedAt: watch.startedAt, duration: watch.elapsed,
            outcome: outcome(result)
        )
        return result
    }

    // Oldest-first snapshot. Callers that want newest-first go through
    // OpsCollapse.rows, which sorts.
    var snapshot: [OpsRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    func clear() {
        lock.lock()
        records = []
        lock.unlock()
        NotificationCenter.default.post(name: Self.didUpdate, object: self)
    }

    private func scheduleNotify() {
        lock.lock()
        guard !notifyScheduled else {
            lock.unlock()
            return
        }
        notifyScheduled = true
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.notifyInterval) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.notifyScheduled = false
            self.lock.unlock()
            NotificationCenter.default.post(name: Self.didUpdate, object: self)
        }
    }

    // MARK: - Ambient trigger

    // The *why* behind an operation is known by the caller that started the
    // pass, not by the wrapper that spawns the process — GitStatusMonitor knows
    // an FSEvents burst asked for the refresh; runProcess only sees argv. A
    // scoped, thread-local trigger lets the knowing caller state it once and
    // have every nested spawn inherit it, instead of threading a parameter
    // through six layers that don't care.
    //
    // Thread-local is sound here because every instrumented site runs its
    // subprocesses synchronously on the thread that set the trigger; the
    // restore is a `defer`, so an early return or a throw can't leak it onto a
    // pooled GCD thread.
    private static let triggerKey = "dev.kosych.suit.opsTrigger"

    static var currentTrigger: String? {
        Thread.current.threadDictionary[triggerKey] as? String
    }

    @discardableResult
    static func withTrigger<T>(_ trigger: String, _ body: () -> T) -> T {
        let previous = Thread.current.threadDictionary[triggerKey]
        Thread.current.threadDictionary[triggerKey] = trigger
        defer { Thread.current.threadDictionary[triggerKey] = previous }
        return body()
    }
}
