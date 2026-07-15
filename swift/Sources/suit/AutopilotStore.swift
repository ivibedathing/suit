import Foundation

// Autopilot persistence: everything the engine needs to
// survive a relaunch lives under ~/.suit/autopilot/. Follows the
// FavoritesStore pattern (static shared, didUpdate, all-optional Codable
// model, $HOME-resolved paths, atomic writes) — but Foundation-only so the
// scheduler/store logic compiles standalone for scratch tests.
//
//   state.json      — the current run + block/pause flags + last usage
//                     snapshot; atomically rewritten on every transition.
//   history.jsonl   — append-only CompletedRun rows, one JSON object per line.
//   autopilot.log   — human-readable timestamped event lines (opened as a
//                     regular viewer tab by the "Autopilot: Show Log" command).
//   logs/<slug>/    — per-run gate output: build-<n>.log, review-<n>.log.
//
// Tab ids are per-launch UUIDs and are never persisted here — relaunch
// adoption re-resolves or respawns the worker tab (STANDALONE.md §2.10).

// One in-flight run, mirrored to state.json on every stage transition.
// `stage` stays a plain string: the engine owns the stage enum and the store
// must not depend on it (transient stages like preflight/spawning are never
// written here).
struct AutopilotRun: Codable {
    // Stable across relaunches — becomes the history row's run_id.
    var id: String = UUID().uuidString
    var phaseId: Int
    var title: String
    var slug: String
    var branch: String
    var worktreePath: String
    var stage: String
    var startedAt: TimeInterval
    // The pinned worker session (current one; a --continue respawn re-pins).
    var sessionId: String?
    var prNumber: Int?
    var buildAttempts: Int = 0
    var reviewAttempts: Int = 0
    var mergeAttempts: Int = 0
    var nudgeCount: Int = 0
    var lastNudgeAt: TimeInterval?
    // The phase's heading + body, verbatim at spawn time — the contract the
    // worker and the review gate both judge against (immune to concurrent
    // ROADMAP.md edits).
    var specSnapshot: String
    // Sampled from the pinned session file on every didUpdate, keeping the
    // max / accumulating — session files get pruned, so the history row's
    // cost/context/session data has to live here (§2.10).
    var costUSD: Double?
    var maxContextPct: Double?
    var sessionIds: [String] = []
    // Per-phase routing annotations snapshotted from the RoadmapPhase at
    // spawn (like specSnapshot): the worker launches with these as
    // ANTHROPIC_MODEL / CLAUDE_CODE_EFFORT_LEVEL. nil = session default.
    var model: String?
    var effort: String?
    // Hash of the last diff a review verdict was actually issued for: when
    // the next review attempt sees a byte-identical diff, the gate skips the
    // headless claude call (the verdict couldn't change) and re-sends
    // unchanged-diff feedback instead.
    var lastReviewedDiffHash: String?

    // Explicit keys so the defaulted vars decode leniently from older files.
    private enum CodingKeys: String, CodingKey {
        case id, phaseId, title, slug, branch, worktreePath, stage, startedAt
        case sessionId, prNumber, buildAttempts, reviewAttempts, mergeAttempts
        case nudgeCount, lastNudgeAt, specSnapshot
        case costUSD, maxContextPct, sessionIds
        case model, effort, lastReviewedDiffHash
    }

    init(phaseId: Int, title: String, slug: String, branch: String,
         worktreePath: String, stage: String, startedAt: TimeInterval,
         specSnapshot: String, model: String? = nil, effort: String? = nil) {
        self.phaseId = phaseId
        self.title = title
        self.slug = slug
        self.branch = branch
        self.worktreePath = worktreePath
        self.stage = stage
        self.startedAt = startedAt
        self.specSnapshot = specSnapshot
        self.model = model
        self.effort = effort
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        phaseId = try c.decode(Int.self, forKey: .phaseId)
        title = try c.decode(String.self, forKey: .title)
        slug = try c.decode(String.self, forKey: .slug)
        branch = try c.decode(String.self, forKey: .branch)
        worktreePath = try c.decode(String.self, forKey: .worktreePath)
        stage = try c.decode(String.self, forKey: .stage)
        startedAt = try c.decode(TimeInterval.self, forKey: .startedAt)
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        prNumber = try c.decodeIfPresent(Int.self, forKey: .prNumber)
        buildAttempts = try c.decodeIfPresent(Int.self, forKey: .buildAttempts) ?? 0
        reviewAttempts = try c.decodeIfPresent(Int.self, forKey: .reviewAttempts) ?? 0
        mergeAttempts = try c.decodeIfPresent(Int.self, forKey: .mergeAttempts) ?? 0
        nudgeCount = try c.decodeIfPresent(Int.self, forKey: .nudgeCount) ?? 0
        lastNudgeAt = try c.decodeIfPresent(TimeInterval.self, forKey: .lastNudgeAt)
        specSnapshot = try c.decode(String.self, forKey: .specSnapshot)
        costUSD = try c.decodeIfPresent(Double.self, forKey: .costUSD)
        maxContextPct = try c.decodeIfPresent(Double.self, forKey: .maxContextPct)
        sessionIds = try c.decodeIfPresent([String].self, forKey: .sessionIds) ?? []
        model = try c.decodeIfPresent(String.self, forKey: .model)
        effort = try c.decodeIfPresent(String.self, forKey: .effort)
        lastReviewedDiffHash = try c.decodeIfPresent(String.self, forKey: .lastReviewedDiffHash)
    }
}

// One finished run — a history.jsonl row (snake_case keys per §2.10 so the
// file is greppable/jq-able alongside the other ~/.suit JSON artifacts).
struct CompletedRun: Codable {
    enum Outcome: String, Codable {
        case merged, blocked, skipped, aborted
    }

    var runId: String
    var phase: Int
    var title: String
    var slug: String
    var branch: String
    var startedAt: TimeInterval
    var endedAt: TimeInterval
    var attempts: Int
    var outcome: Outcome
    var prURL: String?
    var costUSD: Double?
    var maxContextPct: Double?
    var sessionIds: [String]
    var blockedReason: String?

    private enum CodingKeys: String, CodingKey {
        case runId = "run_id"
        case phase, title, slug, branch
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case attempts, outcome
        case prURL = "pr_url"
        case costUSD = "cost_usd"
        case maxContextPct = "max_context_pct"
        case sessionIds = "session_ids"
        case blockedReason = "blocked_reason"
    }
}

final class AutopilotStore {
    static let didUpdate = Notification.Name("AutopilotStoreDidUpdate")

    // Which repo this store belongs to. Every autopilot instance owns its own
    // store, keyed by project root, so several can run concurrently without
    // trampling each other's state.json / history / logs.
    let projectRoot: String

    // The persisted block: `reason` is the engine's AutopilotBlockReason
    // rawValue (a string here so the store stays engine-independent),
    // `message` the human line the footer/notification shows.
    struct Blocked: Codable {
        var reason: String
        var message: String
        var at: TimeInterval
        var phaseId: Int?
    }

    // The last usage snapshot the scheduler saw, mirrored so a relaunch can
    // still show "next run ~03:40" before fresh usage arrives (§2.4). A
    // Codable twin of the scheduler's snapshot — plain values, epoch dates.
    struct Snapshot: Codable {
        var fiveHourPct: Double?
        var sevenDayPct: Double?
        var modelWeeklyMaxPct: Double?
        var fiveHourResetsAt: TimeInterval?
        var sevenDayResetsAt: TimeInterval?
        var capturedAt: TimeInterval
    }

    private struct Model: Codable {
        // Optional so partial / older state.json files still decode.
        var projectRoot: String?
        var run: AutopilotRun?
        var blocked: Blocked?
        var pausedByUser: Bool?
        var lastSnapshot: Snapshot?
    }

    private var model = Model()

    // $HOME rather than NSHomeDirectory() so tests/harnesses can point the
    // store at a scratch home (same reasoning as FavoritesStore).
    static func autopilotRoot() -> URL {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: home + "/.suit/autopilot")
    }

    // The legacy single-autopilot layout wrote state.json / history.jsonl /
    // autopilot.log / logs/ straight into ~/.suit/autopilot. The per-repo
    // layout nests them under repos/<slug>/; migrateLegacyIfNeeded moves the
    // old files into the configured primary repo's slot on first launch.
    static func legacyBaseDirectory() -> URL { autopilotRoot() }

    // A filesystem-safe, collision-resistant directory name for a repo path:
    // the last path component (sanitised) plus a short hash of the full path.
    static func slug(for root: String) -> String {
        let trimmed = root.hasSuffix("/") ? String(root.dropLast()) : root
        let last = (trimmed as NSString).lastPathComponent
        let safe = String(last.unicodeScalars.map { scalar -> Character in
            let ok = (scalar >= "A" && scalar <= "Z") || (scalar >= "a" && scalar <= "z")
                || (scalar >= "0" && scalar <= "9") || scalar == "." || scalar == "_" || scalar == "-"
            return ok ? Character(scalar) : "-"
        }).prefix(40)
        // djb2 over the full path — stable, no Foundation hashing seed.
        var hash: UInt64 = 5381
        for byte in trimmed.utf8 { hash = (hash &* 33) ^ UInt64(byte) }
        let suffix = String(hash, radix: 16)
        return (safe.isEmpty ? "repo" : String(safe)) + "-" + suffix
    }

    private let baseDirectory: URL
    private let stateFileURL: URL
    private let historyFileURL: URL
    let logFileURL: URL

    init(projectRoot: String) {
        self.projectRoot = projectRoot
        let base = Self.autopilotRoot()
            .appendingPathComponent("repos")
            .appendingPathComponent(Self.slug(for: projectRoot))
        baseDirectory = base
        stateFileURL = base.appendingPathComponent("state.json")
        historyFileURL = base.appendingPathComponent("history.jsonl")
        logFileURL = base.appendingPathComponent("autopilot.log")
        load()
    }

    // MARK: - Current run / flags (state.json, atomic rewrite per transition)

    var run: AutopilotRun? { model.run }

    func setRun(_ run: AutopilotRun?) {
        model.run = run
        save()
    }

    // In-place mutation for the frequent small transitions (stage change,
    // attempt bump, session pin, cost/context sampling). No-op without a run.
    func updateRun(_ mutate: (inout AutopilotRun) -> Void) {
        guard var run = model.run else { return }
        mutate(&run)
        model.run = run
        save()
    }

    var blocked: Blocked? { model.blocked }

    func setBlocked(_ blocked: Blocked?) {
        model.blocked = blocked
        save()
    }

    var pausedByUser: Bool { model.pausedByUser ?? false }

    func setPausedByUser(_ paused: Bool) {
        model.pausedByUser = paused
        save()
    }

    var lastSnapshot: Snapshot? { model.lastSnapshot }

    func setLastSnapshot(_ snapshot: Snapshot?) {
        model.lastSnapshot = snapshot
        save()
    }

    // Ensure a state.json exists for this repo even before its first run, so a
    // user-started ("Start Autopilot Here") but still-idle instance is
    // re-adopted after a relaunch instead of being forgotten.
    func markActive() {
        save()
    }

    // Tear down this repo's persisted slot entirely (dashboard "Stop"): the
    // instance is gone, so nothing should re-adopt it next launch.
    func deleteSlot() {
        try? FileManager.default.removeItem(at: baseDirectory)
    }

    // MARK: - History (history.jsonl, append-only)

    func appendHistory(_ completed: CompletedRun) {
        // JSONEncoder's default output is compact single-line JSON — exactly
        // one JSONL row.
        guard let data = try? JSONEncoder().encode(completed) else { return }
        append(data + [0x0A], to: historyFileURL)
    }

    // MARK: - Human-readable event log (autopilot.log)

    private static let logTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    func log(_ message: String) {
        let stamp = Self.logTimestampFormatter.string(from: Date())
        guard let data = (stamp + "  " + message + "\n").data(using: .utf8) else { return }
        append(data, to: logFileURL)
    }

    // Cross-instance events (enable/disable, Start Here, Stop) that don't
    // belong to any one repo — written to the top-level ~/.suit/autopilot log.
    static let globalLogURL = autopilotRoot().appendingPathComponent("autopilot.log")

    static func logGlobal(_ message: String) {
        let stamp = logTimestampFormatter.string(from: Date())
        guard let data = (stamp + "  " + message + "\n").data(using: .utf8) else { return }
        let dir = autopilotRoot()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: globalLogURL.path) {
            try? data.write(to: globalLogURL, options: .atomic)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: globalLogURL) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(data)
    }

    // MARK: - Gate logs (logs/<slug>/build-N.log, review-N.log)

    // Returns the file URL for a gate attempt's output, creating the per-run
    // directory; the gate runner streams into it.
    func buildLogURL(slug: String, attempt: Int) -> URL {
        gateLogURL(slug: slug, name: "build-\(attempt).log")
    }

    func reviewLogURL(slug: String, attempt: Int) -> URL {
        gateLogURL(slug: slug, name: "review-\(attempt).log")
    }

    private func gateLogURL(slug: String, name: String) -> URL {
        let directory = baseDirectory
            .appendingPathComponent("logs")
            .appendingPathComponent(slug)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }

    // MARK: - Legacy migration (single-autopilot → per-repo layout)

    // One-time, best-effort move of the old top-level state.json / history.jsonl
    // / autopilot.log / logs/ into the configured primary repo's slot. Runs
    // before any store is constructed for that repo; a no-op once the repo slot
    // exists or when there's nothing to migrate.
    static func migrateLegacyIfNeeded(primaryRoot: String) {
        guard !primaryRoot.isEmpty else { return }
        let fm = FileManager.default
        let legacy = legacyBaseDirectory()
        let legacyState = legacy.appendingPathComponent("state.json")
        guard fm.fileExists(atPath: legacyState.path) else { return }
        let target = autopilotRoot().appendingPathComponent("repos").appendingPathComponent(slug(for: primaryRoot))
        // If the repo slot already has state, the migration already happened.
        if fm.fileExists(atPath: target.appendingPathComponent("state.json").path) { return }
        try? fm.createDirectory(at: target, withIntermediateDirectories: true)
        for name in ["state.json", "history.jsonl", "autopilot.log"] {
            let from = legacy.appendingPathComponent(name)
            let to = target.appendingPathComponent(name)
            if fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) {
                try? fm.moveItem(at: from, to: to)
            }
        }
        let legacyLogs = legacy.appendingPathComponent("logs")
        let targetLogs = target.appendingPathComponent("logs")
        if fm.fileExists(atPath: legacyLogs.path), !fm.fileExists(atPath: targetLogs.path) {
            try? fm.moveItem(at: legacyLogs, to: targetLogs)
        }
    }

    // Repo slots persisted on disk (repos/<slug>/state.json present) — the
    // manager scans these on launch to re-adopt every autopilot that was live.
    static func persistedRepoSlugs() -> [String] {
        let reposDir = autopilotRoot().appendingPathComponent("repos")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: reposDir.path) else { return [] }
        return entries.filter {
            FileManager.default.fileExists(atPath: reposDir.appendingPathComponent($0).appendingPathComponent("state.json").path)
        }
    }

    // The project root a persisted slot belongs to, read back from its
    // state.json (the run's worktree/branch alone can't name the repo). Stored
    // explicitly so a slug never has to be reversed into a path.
    static func projectRoot(forSlug slug: String) -> String? {
        let stateURL = autopilotRoot().appendingPathComponent("repos").appendingPathComponent(slug).appendingPathComponent("state.json")
        guard let data = try? Data(contentsOf: stateURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["projectRoot"] as? String
    }

    // MARK: - Disk

    private func load() {
        guard let data = try? Data(contentsOf: stateFileURL),
              let decoded = try? JSONDecoder().decode(Model.self, from: data) else { return }
        model = decoded
    }

    private func save() {
        // Stamp the repo path so a launch scan can map a slug slot back to its
        // project root without reversing the hash.
        model.projectRoot = projectRoot
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(model) {
            try? data.write(to: stateFileURL, options: .atomic)
        }
        NotificationCenter.default.post(name: Self.didUpdate, object: self)
    }

    private func append(_ data: Data, to url: URL) {
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? data.write(to: url, options: .atomic)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(data)
    }
}
