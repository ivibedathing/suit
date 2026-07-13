import Foundation

// Fleet activity feed / daily digest: the chronological
// record of what *moved* across the fleet — sessions finishing, PRs opening/
// merging, CI passing/failing, Autopilot runs merging/blocking — plus a
// "what happened today" recap.
//
// This file is the UI-free, standalone-compilable core (the RoadmapParser /
// FeedbackRouting / Recipes / FileEdit pattern, Foundation-only, no AppKit and
// no app deps), so `scripts/activity-test.sh` can compile it in isolation and
// assert the feed ordering / routing / daily-digest rollup without any UI. The
// AppKit halves live in ActivityRecorder.swift (the producers) and
// ActivityFeedController.swift (the panel).
//
//   ~/.suit/activity.jsonl — append-only, one JSON object per line (the
//   usage-history.jsonl / autopilot history.jsonl pattern), so activity
//   survives session-file pruning and stays greppable/jq-able.

// MARK: - Kinds

// The notable transitions the feed records. rawValue is the persisted string
// (snake_case, greppable), so new kinds can be added without breaking old rows.
enum ActivityKind: String, Codable, CaseIterable {
    case sessionDone = "session_done"
    case sessionNeedsInput = "session_needs_input"
    case prOpened = "pr_opened"
    case prMerged = "pr_merged"
    case ciPass = "ci_pass"
    case ciFail = "ci_fail"
    case autopilotMerged = "autopilot_merged"
    case autopilotBlocked = "autopilot_blocked"
    // Cost budget guardrails: a session/task crossed its
    // configured spend cap (warned, or auto-interrupted).
    case budgetTripped = "budget_tripped"
    // Auto-/compact guardrails: a session idled past the context
    // threshold and Suit typed /compact into it.
    case autoCompacted = "auto_compacted"

    // Human label for the filter menu and row subtitles.
    var label: String {
        switch self {
        case .sessionDone: return "Session done"
        case .sessionNeedsInput: return "Needs input"
        case .prOpened: return "PR opened"
        case .prMerged: return "PR merged"
        case .ciPass: return "CI passed"
        case .ciFail: return "CI failed"
        case .autopilotMerged: return "Autopilot merged"
        case .autopilotBlocked: return "Autopilot blocked"
        case .budgetTripped: return "Budget tripped"
        case .autoCompacted: return "Auto-compacted"
        }
    }

    // SF Symbol name for the row glyph. Kept as a plain string so the core
    // stays Foundation-only; the view resolves it to an NSImage.
    var glyph: String {
        switch self {
        case .sessionDone: return "checkmark.circle.fill"
        case .sessionNeedsInput: return "bell.fill"
        case .prOpened: return "arrow.triangle.pull"
        case .prMerged: return "arrow.triangle.merge"
        case .ciPass: return "checkmark.seal.fill"
        case .ciFail: return "xmark.octagon.fill"
        case .autopilotMerged: return "sparkles"
        case .autopilotBlocked: return "hand.raised.fill"
        case .budgetTripped: return "dollarsign.circle.fill"
        case .autoCompacted: return "rectangle.compress.vertical"
        }
    }

    // Semantic tone, mapped by the view to a Theme color (kept out of the core
    // so no AppKit dependency leaks in).
    enum Tone { case positive, negative, attention, neutral }

    var tone: Tone {
        switch self {
        case .sessionDone, .prMerged, .ciPass, .autopilotMerged: return .positive
        case .ciFail, .autopilotBlocked: return .negative
        case .sessionNeedsInput, .budgetTripped: return .attention
        case .prOpened, .autoCompacted: return .neutral
        }
    }
}

// MARK: - Routing

// Where a row click goes. `.session` focuses the pane hosting that session,
// `.pr` opens the PR on GitHub, `.autopilotLog` opens the Autopilot log tab,
// `.none` is inert (nothing to route to).
enum ActivityRoute: Equatable {
    case session(String)
    case pr(String)
    case autopilotLog
    case none
}

// MARK: - Event

// One activity row. snake_case keys so the JSONL is greppable alongside the
// other ~/.suit JSON artifacts; every field but id/kind/timestamp/title is
// optional so old/partial rows decode leniently.
struct ActivityEvent: Codable, Equatable {
    // Stable, deterministic id — the store dedups on it so a producer can fire
    // idempotently from more than one call site (e.g. a CI failure surfaced by
    // several windows' feedback passes records once).
    var id: String
    var kind: ActivityKind
    var timestamp: TimeInterval   // epoch seconds
    var title: String
    var detail: String?
    var repo: String?
    var sessionId: String?
    var worktree: String?
    var prNumber: Int?
    var prURL: String?

    private enum CodingKeys: String, CodingKey {
        case id, kind, timestamp, title, detail, repo
        case sessionId = "session_id"
        case worktree
        case prNumber = "pr_number"
        case prURL = "pr_url"
    }

    init(id: String, kind: ActivityKind, timestamp: TimeInterval, title: String,
         detail: String? = nil, repo: String? = nil, sessionId: String? = nil,
         worktree: String? = nil, prNumber: Int? = nil, prURL: String? = nil) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
        self.title = title
        self.detail = detail
        self.repo = repo
        self.sessionId = sessionId
        self.worktree = worktree
        self.prNumber = prNumber
        self.prURL = prURL
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(ActivityKind.self, forKey: .kind)
        timestamp = try c.decode(TimeInterval.self, forKey: .timestamp)
        title = try c.decode(String.self, forKey: .title)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        repo = try c.decodeIfPresent(String.self, forKey: .repo)
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        worktree = try c.decodeIfPresent(String.self, forKey: .worktree)
        prNumber = try c.decodeIfPresent(Int.self, forKey: .prNumber)
        prURL = try c.decodeIfPresent(String.self, forKey: .prURL)
    }

    // A row click routes to the most specific target it carries: its session
    // (steer/focus), else its PR (open on GitHub), else — for Autopilot rows —
    // the log; otherwise nothing.
    var route: ActivityRoute {
        if let sessionId, !sessionId.isEmpty { return .session(sessionId) }
        if let prURL, !prURL.isEmpty { return .pr(prURL) }
        switch kind {
        case .autopilotMerged, .autopilotBlocked: return .autopilotLog
        default: return .none
        }
    }
}

// MARK: - Feed

// Pure projection of the raw rows into what the panel shows: newest-first
// ordering, plus the filter and the distinct-value lists behind its menus.
enum ActivityFeed {
    // Newest-first. Ties (equal timestamps) keep input order reversed so a
    // burst recorded in sequence still reads last-first, and the sort stays
    // deterministic.
    static func ordered(_ events: [ActivityEvent]) -> [ActivityEvent] {
        events.enumerated()
            .sorted { a, b in
                if a.element.timestamp != b.element.timestamp {
                    return a.element.timestamp > b.element.timestamp
                }
                return a.offset > b.offset
            }
            .map { $0.element }
    }

    // Filters by any combination of repo / session / kind (nil = "any").
    static func filter(
        _ events: [ActivityEvent],
        repo: String? = nil,
        sessionId: String? = nil,
        kind: ActivityKind? = nil
    ) -> [ActivityEvent] {
        events.filter { event in
            if let repo, event.repo != repo { return false }
            if let sessionId, event.sessionId != sessionId { return false }
            if let kind, event.kind != kind { return false }
            return true
        }
    }

    // The distinct repos present, sorted — the repo filter menu's options.
    static func repos(in events: [ActivityEvent]) -> [String] {
        Array(Set(events.compactMap { $0.repo }.filter { !$0.isEmpty })).sorted()
    }

    // The distinct kinds present, in ActivityKind declaration order — the kind
    // filter menu's options.
    static func kinds(in events: [ActivityEvent]) -> [ActivityKind] {
        let present = Set(events.map { $0.kind })
        return ActivityKind.allCases.filter { present.contains($0) }
    }
}

// MARK: - Daily digest

// The "what happened today" recap: counts + a few highlight lines rolled up
// from one calendar day's rows.
struct DailyDigest: Equatable {
    var dayStart: TimeInterval
    var sessionsFinished: Int
    var prsMerged: Int
    var ciFailures: Int
    var autopilotMerged: Int
    var highlights: [String]

    var total: Int { sessionsFinished + prsMerged + ciFailures + autopilotMerged }
    var isEmpty: Bool { total == 0 }

    // A one-line summary for a notification body / panel header. Empty when
    // nothing happened.
    var summary: String {
        guard !isEmpty else { return "No activity today." }
        var parts: [String] = []
        if sessionsFinished > 0 { parts.append("\(sessionsFinished) session\(sessionsFinished == 1 ? "" : "s") finished") }
        if prsMerged > 0 { parts.append("\(prsMerged) PR\(prsMerged == 1 ? "" : "s") merged") }
        if autopilotMerged > 0 { parts.append("\(autopilotMerged) autopilot merge\(autopilotMerged == 1 ? "" : "s")") }
        if ciFailures > 0 { parts.append("\(ciFailures) CI failure\(ciFailures == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    // Rolls up the rows whose timestamp falls on the same calendar day as
    // `day` (using `calendar`, so the harness can pin a fixed timezone). PR
    // merges count both plain PR merges and Autopilot merges (an Autopilot run
    // that merged is also a PR that merged, but they're tracked separately so
    // the summary can distinguish them). Highlights are the day's most notable
    // rows (merges + CI failures), newest-first, capped.
    static func rollup(
        events: [ActivityEvent],
        day: Date,
        calendar: Calendar = .current,
        maxHighlights: Int = 5
    ) -> DailyDigest {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        let startEpoch = dayStart.timeIntervalSince1970
        let endEpoch = dayEnd.timeIntervalSince1970

        let today = events.filter { $0.timestamp >= startEpoch && $0.timestamp < endEpoch }

        var sessionsFinished = 0
        var prsMerged = 0
        var ciFailures = 0
        var autopilotMerged = 0
        for event in today {
            switch event.kind {
            case .sessionDone: sessionsFinished += 1
            case .prMerged: prsMerged += 1
            case .ciFail: ciFailures += 1
            case .autopilotMerged: autopilotMerged += 1
            default: break
            }
        }

        let notable: Set<ActivityKind> = [.prMerged, .autopilotMerged, .ciFail, .autopilotBlocked]
        let highlights = ActivityFeed.ordered(today.filter { notable.contains($0.kind) })
            .prefix(maxHighlights)
            .map { "\($0.kind.label): \($0.title)" }

        return DailyDigest(
            dayStart: startEpoch,
            sessionsFinished: sessionsFinished,
            prsMerged: prsMerged,
            ciFailures: ciFailures,
            autopilotMerged: autopilotMerged,
            highlights: Array(highlights)
        )
    }
}

// MARK: - Store

// Append-only persistence + an in-memory mirror. FavoritesStore/AutopilotStore
// pattern — static shared, didUpdate, $HOME-resolved path, but Foundation-only
// so the harness compiles it standalone. Dedups on ActivityEvent.id so a
// producer firing from several call sites records once.
final class ActivityStore {
    static let shared = ActivityStore()
    static let didUpdate = Notification.Name("ActivityStoreDidUpdate")

    // Newest rows are most-used; keep the file bounded by rewriting to the tail
    // once it grows past this. A generous ceiling — activity is one line each.
    private static let maxRows = 5_000

    private(set) var events: [ActivityEvent] = []
    private var knownIds = Set<String>()

    // $HOME rather than NSHomeDirectory() so harnesses can sandbox the path
    // (same reasoning as the other ~/.suit stores).
    private let fileURL: URL

    // The default lives on ~/.suit/activity.jsonl; the initializer takes an
    // override so a test can point at a scratch file without an env dance.
    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
            self.fileURL = URL(fileURLWithPath: home + "/.suit/activity.jsonl")
        }
        load()
    }

    // Records an event unless its id was already seen — returns whether it was
    // actually appended (so callers can post a notification only on the first
    // sighting). The caller stamps `timestamp`; the store is deterministic.
    @discardableResult
    func record(_ event: ActivityEvent) -> Bool {
        guard !knownIds.contains(event.id) else { return false }
        knownIds.insert(event.id)
        events.append(event)
        append(event)
        if events.count > Self.maxRows { compact() }
        NotificationCenter.default.post(name: Self.didUpdate, object: self)
        return true
    }

    // MARK: - Disk

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else { return }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let event = try? JSONDecoder().decode(ActivityEvent.self, from: lineData) else { continue }
            if knownIds.contains(event.id) { continue }
            knownIds.insert(event.id)
            events.append(event)
        }
    }

    private func append(_ event: ActivityEvent) {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(event) else { return }
        let line = data + [0x0A]
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? line.write(to: fileURL, options: .atomic)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(line)
    }

    // Rewrites the file down to the newest maxRows/2 rows once it overflows —
    // an amortized trim that keeps the file from growing without bound while
    // preserving recent history.
    private func compact() {
        let keep = ActivityFeed.ordered(events).prefix(Self.maxRows / 2)
        // Persist oldest-first so the file's natural order still reads
        // chronologically; the feed re-sorts on load anyway.
        let ordered = Array(keep).sorted { $0.timestamp < $1.timestamp }
        events = ordered
        knownIds = Set(ordered.map { $0.id })
        let encoder = JSONEncoder()
        var blob = Data()
        for event in ordered {
            guard let data = try? encoder.encode(event) else { continue }
            blob.append(data)
            blob.append(0x0A)
        }
        try? blob.write(to: fileURL, options: .atomic)
    }
}
