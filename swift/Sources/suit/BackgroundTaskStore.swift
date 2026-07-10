import Foundation
import Darwin

// The IO layer behind the background-task monitor — the
// ClaudeSessionMonitor/GitStatusMonitor pattern. Watches ~/.suit/tasks/ for the
// JSON records scripts/suit-bg.sh drops there, reconciles each against real
// process liveness (BackgroundTasks.resolveStatus), enriches running tasks with
// a live listening-port probe, and posts `didUpdate`. The reconciliation logic
// itself is pure and lives in BackgroundTasks.swift; this file is just the
// file-watching + process-probe plumbing that can't be unit-tested headlessly.
//
// A record persists after its process exits (that's how an already-finished
// task stays listed), so the store prunes records whose process is long gone.
final class BackgroundTaskStore {
    static let shared = BackgroundTaskStore()
    static let didUpdate = Notification.Name("BackgroundTaskStoreDidUpdate")

    // $HOME first (not NSHomeDirectory()), same as ClaudeSessionMonitor /
    // ClaudeIntegration: the suit-bg wrapper writes to "$HOME/.suit/tasks", and
    // an overridden $HOME sandboxes both sides for harness runs.
    static let tasksDirectory =
        (ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()) + "/.suit/tasks"

    // Finished records are dropped this long after their process last mattered,
    // so the directory doesn't grow without bound.
    private static let pruneAge: TimeInterval = 24 * 60 * 60

    private(set) var tasks: [BackgroundTask] = []

    private let probeQueue = DispatchQueue(label: "dev.kosych.suit.bgtasks")
    private var directorySource: DispatchSourceFileSystemObject?
    private var reloadDebounce: DispatchWorkItem?
    // Cache of the last live port probe per pid, so a settled server isn't
    // re-lsof'd on every 3 s refresh (probing is a subprocess spawn).
    private var portCache: [Int32: Int?] = [:]

    private init() {
        try? FileManager.default.createDirectory(atPath: Self.tasksDirectory, withIntermediateDirectories: true)
        watch()
        DispatchQueue.main.async { [weak self] in self?.reload() }
    }

    private func watch() {
        let fd = open(Self.tasksDirectory, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in self?.scheduleReload() }
        source.setCancelHandler { close(fd) }
        source.resume()
        directorySource = source
    }

    private func scheduleReload() {
        reloadDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        reloadDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    // Re-reads every record and reconciles it against live process state.
    // Called on watcher events and by the app's 3 s heartbeat (a process exit
    // that the wrapper's trap somehow missed changes no file, so a periodic
    // liveness sweep is what catches a crash). The file read + port probes run
    // off the main thread; the resolved list is published back on main.
    func reload() {
        // Snapshot the port cache on the main thread; the probe runs off-main
        // and publishes a fresh cache back, so the dictionary is never mutated
        // and read across threads at once.
        let cacheSnapshot = portCache
        probeQueue.async { [weak self] in
            guard let self else { return }
            let fm = FileManager.default
            let now = Date().timeIntervalSince1970
            var records: [BackgroundTaskRecord] = []
            for name in (try? fm.contentsOfDirectory(atPath: Self.tasksDirectory)) ?? [] where name.hasSuffix(".json") {
                let path = Self.tasksDirectory + "/" + name
                guard let data = fm.contents(atPath: path),
                      let record = BackgroundTasks.parseRecord(data) else { continue }
                // Prune records whose process is gone and that last changed a
                // day ago (best-effort mtime; startedAt as a fallback).
                let touched = ((try? fm.attributesOfItem(atPath: path)[.modificationDate]) as? Date)?
                    .timeIntervalSince1970 ?? record.startedAt
                if !Self.isAlive(record.pid), now - touched > Self.pruneAge {
                    try? fm.removeItem(atPath: path)
                    continue
                }
                records.append(record)
            }

            var newPortCache: [Int32: Int?] = [:]
            let resolved: [BackgroundTask] = records.map { record in
                let alive = Self.isAlive(record.pid)
                var task = BackgroundTasks.resolve(record: record, isAlive: alive)
                // A live server that didn't record its port: probe once and
                // cache. Finished tasks keep whatever the record captured.
                if task.status == .running, task.port == nil {
                    if let cached = cacheSnapshot[record.pid] {
                        task.port = cached
                        newPortCache[record.pid] = cached
                    } else {
                        let probed = Self.listeningPort(ofPid: record.pid)
                        task.port = probed
                        newPortCache[record.pid] = probed
                    }
                }
                return task
            }
            .sorted { $0.startedAt > $1.startedAt }

            DispatchQueue.main.async {
                self.portCache = newPortCache
                self.tasks = resolved
                NotificationCenter.default.post(name: Self.didUpdate, object: self)
            }
        }
    }

    // The tasks whose launching shell sits in a given shell's process subtree —
    // how one monitor pane shows only its own pane's background jobs. Computed
    // against a fresh sysctl parent map each call (process trees move).
    func tasks(underShell shellPid: Int32) -> [BackgroundTask] {
        guard shellPid > 0 else { return tasks }
        let parentMap = Self.processParentMap()
        return tasks.filter { task in
            // The task's own pid subtree first (the backgrounded job is a
            // descendant of the pane's shell while it lives); the record's
            // launching-shell field as a fallback that survives the job's exit.
            if BackgroundTasks.isDescendant(task.pid, of: shellPid, in: parentMap) { return true }
            guard let shell = recordShell(forId: task.id) else { return false }
            return shell == shellPid || BackgroundTasks.isDescendant(shell, of: shellPid, in: parentMap)
        }
    }

    // Reads just the `shell` field of a record by id (the resolved BackgroundTask
    // deliberately doesn't carry it — it's a filtering detail).
    private func recordShell(forId id: String) -> Int32? {
        let path = Self.tasksDirectory + "/" + id + ".json"
        guard let data = FileManager.default.contents(atPath: path),
              let record = BackgroundTasks.parseRecord(data) else { return nil }
        return record.shell
    }

    // Deletes the finished (exited/failed) records so they drop out of every
    // monitor pane — the "Clear Finished" action.
    func clearFinished() {
        let fm = FileManager.default
        for task in tasks where task.status.isFinished {
            try? fm.removeItem(atPath: Self.tasksDirectory + "/" + task.id + ".json")
        }
        reload()
    }

    // MARK: - Process probes

    // A signal-0 kill only checks permission/existence; ESRCH means the pid is
    // gone. EPERM (someone else's process) still means it's alive.
    static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    // One sysctl read of the whole process table → child pid → parent pid,
    // mirroring ClaudeSessionAssigner.processParentMap.
    static func processParentMap() -> [Int32: Int32] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [:] }
        size += size / 8
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 4, &buffer, &size, nil, 0) == 0 else { return [:] }
        let count = size / MemoryLayout<kinfo_proc>.stride
        var map: [Int32: Int32] = [:]
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

    // The listening TCP port a pid is bound to, via lsof — parsed by the pure
    // BackgroundTasks.parseListeningPort. nil when lsof is absent or the process
    // isn't listening.
    private static func listeningPort(ofPid pid: Int32) -> Int? {
        guard let output = runLsof(["-nP", "-p", "\(pid)", "-iTCP", "-sTCP:LISTEN"]) else { return nil }
        return BackgroundTasks.parseListeningPort(lsof: output)
    }

    private static func runLsof(_ args: [String]) -> String? {
        let candidates = ["/usr/sbin/lsof", "/usr/bin/lsof"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
