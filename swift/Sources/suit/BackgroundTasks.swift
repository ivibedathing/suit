import Foundation

// Background-task monitor core (ROADMAP Phase 30), the UI-free, standalone-
// compilable pattern (RoadmapParser / AutopilotScheduler / FeedbackRouting):
// Foundation-only, no app dependencies, so scripts/background-tasks-test.sh can
// compile just this file and assert the pure logic.
//
// Claude Code (and the user) background long-running processes — dev servers,
// test watchers, builds — that from Suit's side are invisible until you scroll
// the shell. The `suit-bg` wrapper (scripts/suit-bg.sh) launches such a process
// with its output captured to a log file and drops a small JSON *record* into
// ~/.suit/tasks/, updating it with the exit code when the process ends. The
// monitor reads those records, reconciles each against live process state, and
// renders command / status / port / a live log tail. Everything reconciliation-
// shaped lives here as pure functions.

// The three states a tracked task can be in — drives the status dot and the
// strip-attention signal (a task flipping to `.failed` pulses its tab).
enum BackgroundTaskStatus: String, Codable {
    case running, exitedClean, failed

    var label: String {
        switch self {
        case .running: return "running"
        case .exitedClean: return "done"
        case .failed: return "failed"
        }
    }

    var isFailed: Bool { self == .failed }
    var isFinished: Bool { self != .running }
}

// The on-disk record written by scripts/suit-bg.sh (and the verification
// harness) into ~/.suit/tasks/<id>.json. `status` is the wrapper's own view
// ("running" while the job runs, "exited" with an `exitCode` once it ends);
// the monitor cross-checks it against real process liveness so a job that
// crashed before the wrapper's exit trap fired still resolves to `.failed`.
struct BackgroundTaskRecord: Codable {
    var id: String
    var command: String
    var pid: Int32
    // The shell that launched the job (the wrapper's $PPID) — the monitor pane
    // filters records to its own shell's process subtree with this.
    var shell: Int32
    var log: String?
    var status: String          // "running" | "exited" | "failed"
    var exitCode: Int?          // present once the job has ended
    var port: Int?              // detected listening port, if any
    var startedAt: Double       // epoch seconds
}

// The resolved view model the UI renders — a record reconciled against live
// process state.
struct BackgroundTask: Equatable {
    var id: String
    var command: String
    var pid: Int32
    var status: BackgroundTaskStatus
    var port: Int?
    var logPath: String?
    var startedAt: Double
}

enum BackgroundTasks {
    static func parseRecord(_ data: Data) -> BackgroundTaskRecord? {
        try? JSONDecoder().decode(BackgroundTaskRecord.self, from: data)
    }

    // The reconciliation rule — a record's own status crossed with whether its
    // pid is still alive:
    //   - "exited" → clean iff exitCode is 0 (or unset), else failed.
    //   - "failed" → failed (the wrapper trapped a non-zero exit).
    //   - "running" (or anything unrecognized) → running while the pid is alive;
    //     a "running" record whose process has vanished means the job died
    //     before the wrapper's trap could record it — a crash, so `.failed`
    //     (and it raises the attention signal).
    static func resolveStatus(record: BackgroundTaskRecord, isAlive: Bool) -> BackgroundTaskStatus {
        switch record.status {
        case "failed":
            return .failed
        case "exited":
            return (record.exitCode ?? 0) == 0 ? .exitedClean : .failed
        default:
            return isAlive ? .running : .failed
        }
    }

    static func resolve(record: BackgroundTaskRecord, isAlive: Bool) -> BackgroundTask {
        BackgroundTask(
            id: record.id,
            command: record.command,
            pid: record.pid,
            status: resolveStatus(record: record, isAlive: isAlive),
            port: record.port,
            logPath: record.log,
            startedAt: record.startedAt
        )
    }

    // The tasks that newly flipped to `.failed` between two monitor snapshots —
    // exactly the ids whose tab should pulse for attention. Only a *transition*
    // into failure fires (an already-failed task doesn't re-pulse on every
    // refresh).
    static func newlyFailed(previous: [BackgroundTask], current: [BackgroundTask]) -> [String] {
        var prev: [String: BackgroundTaskStatus] = [:]
        for task in previous { prev[task.id] = task.status }
        return current
            .filter { $0.status == .failed && prev[$0.id] != .failed }
            .map { $0.id }
    }

    // Pulls the listening port out of `lsof -nP -p <pid> -iTCP -sTCP:LISTEN`
    // output: the NAME column looks like `*:8080`, `127.0.0.1:8080`, or
    // `[::1]:8080 (LISTEN)`. Returns the first port found, nil if none.
    static func parseListeningPort(lsof output: String) -> Int? {
        for line in output.split(separator: "\n") {
            guard line.contains("(LISTEN)") else { continue }
            // The address is the whitespace token holding the `:port` before
            // the "(LISTEN)" marker — take the last colon-separated field of it.
            for token in line.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                guard token.contains(":") else { continue }
                let tail = token.split(separator: ":").last.map(String.init) ?? ""
                // Strip a trailing "->..." (established peers never reach here
                // since we filter to LISTEN, but be defensive) and any bracket.
                let digits = tail.prefix { $0.isNumber }
                if !digits.isEmpty, let port = Int(digits) { return port }
            }
        }
        return nil
    }

    // Process-subtree membership over a child→parent map (the sysctl
    // KERN_PROC_ALL table): is `pid` `ancestor`, or reachable from it by walking
    // parents? The monitor pane filters records to its shell's descendants so
    // one pane shows only its own background jobs.
    static func isDescendant(_ pid: Int32, of ancestor: Int32, in parentMap: [Int32: Int32]) -> Bool {
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
}

// Incremental log tailing (pure): read whatever was appended to a file past a
// byte offset, returning the complete new lines plus the new offset. Shared by
// the monitor pane's DispatchSource live-tail (the TranscriptPane+Tail pattern)
// and the verification harness, so the "tails new log lines" behavior is
// asserted without spinning any UI.
enum LogTail {
    // Returns nil if the file can't be read. A file that shrank below `offset`
    // (truncated in place) is re-read from the start. The returned lines never
    // include a trailing partial line — that waits for the next append.
    static func readAppended(path: String, from offset: UInt64) -> (lines: [String], newOffset: UInt64)? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        var start = offset
        if size < start { start = 0 }
        guard size > start else { return ([], size) }
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return ([], size) }

        // Only whole lines; a final fragment (no trailing newline) is left for
        // the next read by rewinding the offset to just after the last newline.
        var consumed = start
        var lines: [String] = []
        var lineStart = data.startIndex
        var idx = data.startIndex
        while idx < data.endIndex {
            if data[idx] == UInt8(ascii: "\n") {
                let lineData = data[lineStart..<idx]
                lines.append(String(decoding: lineData, as: UTF8.self))
                consumed += UInt64(data.distance(from: lineStart, to: idx)) + 1
                lineStart = data.index(after: idx)
            }
            idx = data.index(after: idx)
        }
        return (lines, consumed)
    }
}
