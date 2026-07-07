import Cocoa
import Darwin

// Claude session awareness (ROADMAP Phase 4). Claude Code hooks + the
// statusline script (scripts/claude/) write one JSON file per session into
// ~/.suit/sessions/; this monitor watches that directory and publishes the
// parsed sessions, and the assigner maps them onto terminal panes by pid
// ancestry (the claude process is a descendant of the pane's shell) with cwd
// as the fallback.

enum ClaudeSessionState: String {
    case working
    case needsInput = "needs-input"
    case done

    // Sessions tab ordering: "needs you first."
    var sortRank: Int {
        switch self {
        case .needsInput: return 0
        case .working: return 1
        case .done: return 2
        }
    }

    var label: String {
        switch self {
        case .working: return "busy"
        case .needsInput: return "needs input"
        case .done: return "done"
        }
    }

    var color: NSColor {
        switch self {
        case .working: return Theme.sessionBusy
        case .needsInput: return Theme.sessionNeedsInput
        case .done: return Theme.sessionDone
        }
    }
}

struct ClaudeSession {
    let id: String
    let state: ClaudeSessionState
    let cwd: String?
    let summary: String?
    let model: String?
    let pid: pid_t?
    let updatedAt: Date
    let transcriptPath: String?
    let sessionName: String?
    let contextPct: Double?
    let costUSD: Double?

    var displayName: String {
        if let sessionName, !sessionName.isEmpty {
            return sessionName
        }
        if let summary, !summary.isEmpty {
            return summary
        }
        if let cwd {
            return (cwd as NSString).lastPathComponent
        }
        return String(id.prefix(8))
    }
}

// Claude Code's global rate-limit usage, written by the statusline script to
// ~/.suit/claude-status.json regardless of which session is active.
struct ClaudeUsage {
    let fiveHourPct: Double?
    let sevenDayPct: Double?
    // Model-scoped weekly limits beyond the all-models one: every other
    // rate_limits key shaped `seven_day_<model>` (e.g. seven_day_fable →
    // "Fable"), so new per-model limits show up without a parser change.
    let modelWeeklies: [(name: String, pct: Double)]
    let capturedAt: Date
}

final class ClaudeSessionMonitor {
    static let shared = ClaudeSessionMonitor()
    static let didUpdate = Notification.Name("ClaudeSessionMonitorDidUpdate")

    // Sessions younger than this are shown; "done" ages out faster since a
    // finished session stops being actionable.
    private static let maxAge: TimeInterval = 12 * 60 * 60
    private static let maxDoneAge: TimeInterval = 2 * 60 * 60
    // Files older than this are deleted on scan so the directory can't grow forever.
    private static let pruneAge: TimeInterval = 7 * 24 * 60 * 60

    private(set) var sessions: [ClaudeSession] = []
    private(set) var usage: ClaudeUsage?

    private let sessionsDirectory = NSHomeDirectory() + "/.suit/sessions"
    private let statusFile = NSHomeDirectory() + "/.suit/claude-status.json"

    private var directorySource: DispatchSourceFileSystemObject?
    private var parentSource: DispatchSourceFileSystemObject?
    private var reloadDebounce: DispatchWorkItem?

    private init() {
        try? FileManager.default.createDirectory(atPath: sessionsDirectory, withIntermediateDirectories: true)
        watch()
        // Deferred: reload() posts didUpdate, and an observer calling back into
        // `.shared` while this initializer is still inside dispatch_once traps.
        DispatchQueue.main.async { [weak self] in
            self?.reload()
        }
    }

    // Directory-level vnode watchers: session files are small and rewritten
    // atomically (mv), so a .write event on the directory is the reliable signal.
    private func watch() {
        directorySource = watchDirectory(sessionsDirectory)
        // claude-status.json lives in ~/.suit itself.
        parentSource = watchDirectory((statusFile as NSString).deletingLastPathComponent)
    }

    private func watchDirectory(_ path: String) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            self?.scheduleReload()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        return source
    }

    private func scheduleReload() {
        reloadDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        reloadDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    // Re-reads every session file and the global usage snapshot. Called on
    // watcher events and by the app's periodic refresh (process trees change
    // without any file event).
    func reload() {
        let fm = FileManager.default
        var loaded: [ClaudeSession] = []
        let now = Date()

        for name in (try? fm.contentsOfDirectory(atPath: sessionsDirectory)) ?? [] where name.hasSuffix(".json") {
            let path = sessionsDirectory + "/" + name
            guard let data = fm.contents(atPath: path),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["session_id"] as? String else { continue }

            let updatedAt = Date(timeIntervalSince1970: (object["updated_at"] as? Double) ?? 0)
            if now.timeIntervalSince(updatedAt) > Self.pruneAge {
                try? fm.removeItem(atPath: path)
                continue
            }

            let state = (object["state"] as? String).flatMap(ClaudeSessionState.init(rawValue:)) ?? .working
            let age = now.timeIntervalSince(updatedAt)
            if age > Self.maxAge || (state == .done && age > Self.maxDoneAge) {
                continue
            }

            loaded.append(ClaudeSession(
                id: id,
                state: state,
                cwd: object["cwd"] as? String,
                summary: object["summary"] as? String,
                model: object["model"] as? String,
                pid: (object["pid"] as? Int).map(pid_t.init),
                updatedAt: updatedAt,
                transcriptPath: object["transcript_path"] as? String,
                sessionName: object["session_name"] as? String,
                contextPct: (object["context_pct"] as? NSNumber)?.doubleValue,
                costUSD: (object["cost_usd"] as? NSNumber)?.doubleValue
            ))
        }

        sessions = loaded.sorted {
            ($0.state.sortRank, $1.updatedAt.timeIntervalSince1970) < ($1.state.sortRank, $0.updatedAt.timeIntervalSince1970)
        }
        usage = Self.readUsage(path: statusFile)
        NotificationCenter.default.post(name: Self.didUpdate, object: self)
    }

    private static func readUsage(path: String) -> ClaudeUsage? {
        guard let data = FileManager.default.contents(atPath: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let limits = object["rate_limits"] as? [String: Any]
        func pct(_ key: String) -> Double? {
            (limits?[key] as? [String: Any])?["used_percentage"] as? Double
        }
        let captured = Date(timeIntervalSince1970: (object["captured_at"] as? Double) ?? 0)
        // A snapshot from a long-dead session shouldn't show as live usage.
        guard Date().timeIntervalSince(captured) < 30 * 60 else { return nil }
        var modelWeeklies: [(name: String, pct: Double)] = []
        for key in (limits ?? [:]).keys where key.hasPrefix("seven_day_") {
            guard let value = pct(key) else { continue }
            let name = key.dropFirst("seven_day_".count)
                .replacingOccurrences(of: "_", with: " ").capitalized
            modelWeeklies.append((name, value))
        }
        modelWeeklies.sort { $0.name < $1.name }
        return ClaudeUsage(
            fiveHourPct: pct("five_hour"), sevenDayPct: pct("seven_day"),
            modelWeeklies: modelWeeklies, capturedAt: captured
        )
    }

    // Snapshot of pane→session mapping state; build once per refresh pass so
    // the process table is read once, not once per pane.
    func makeAssigner() -> ClaudeSessionAssigner {
        ClaudeSessionAssigner(sessions: sessions)
    }
}

// Maps a pane (its shell pid + cwd) to the session running inside it.
final class ClaudeSessionAssigner {
    private let sessions: [ClaudeSession]
    private let parentMap: [pid_t: pid_t]

    init(sessions: [ClaudeSession]) {
        self.sessions = sessions
        self.parentMap = sessions.contains(where: { $0.pid != nil }) ? Self.processParentMap() : [:]
    }

    func session(forShellPid shellPid: pid_t, cwd: String?) -> ClaudeSession? {
        // pid ancestry is authoritative: the claude process the hooks reported
        // sits somewhere under the pane's shell.
        for session in sessions {
            guard let pid = session.pid else { continue }
            if isDescendant(pid, of: shellPid) {
                return session
            }
        }
        // Fallback: same working directory, newest wins. Catches sessions whose
        // pid discovery failed (or that outlived their process — "done").
        guard let cwd else { return nil }
        return sessions
            .filter { $0.cwd == cwd }
            .max { $0.updatedAt < $1.updatedAt }
    }

    private func isDescendant(_ pid: pid_t, of ancestor: pid_t) -> Bool {
        guard pid > 0, ancestor > 0 else { return false }
        var current = pid
        var hops = 0
        while current > 1, hops < 64 {
            if current == ancestor { return true }
            guard let parent = parentMap[current] else { return false }
            current = parent
            hops += 1
        }
        return false
    }

    // One sysctl read of the whole process table → child pid → parent pid.
    private static func processParentMap() -> [pid_t: pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [:] }
        // Headroom for processes spawned between the two calls.
        size += size / 8
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 4, &buffer, &size, nil, 0) == 0 else { return [:] }

        let count = size / MemoryLayout<kinfo_proc>.stride
        var map: [pid_t: pid_t] = [:]
        map.reserveCapacity(count)
        buffer.withUnsafeBytes { raw in
            let procs = raw.bindMemory(to: kinfo_proc.self)
            for i in 0..<count {
                let proc = procs[i]
                map[proc.kp_proc.p_pid] = proc.kp_eproc.e_ppid
            }
        }
        return map
    }
}
