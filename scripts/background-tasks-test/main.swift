import Foundation

// Standalone logic test for the Phase 30 background-task monitor core. Compiled
// with only swift/Sources/suit/BackgroundTasks.swift (Foundation-only, no app
// deps) — the RoadmapParser / AutopilotScheduler / FeedbackRouting pattern.
// Exercises the pure reconciliation (record → status crossed with liveness),
// the strip-attention transition signal, the lsof port parser, process-subtree
// membership, and the incremental log tail against fixtures with known answers.
// Prints PASS/FAIL and exits non-zero on any failure.

var failures = 0
func check(_ name: String, _ condition: Bool) {
    print("\(condition ? "PASS" : "FAIL"): \(name)")
    if !condition { failures += 1 }
}

// MARK: - Record parsing

do {
    let json = """
    {"id":"t1","command":"npm run dev","pid":4321,"shell":900,"log":"/tmp/t1.log","status":"running","exitCode":null,"port":3000,"startedAt":1700000000}
    """.data(using: .utf8)!
    let record = BackgroundTasks.parseRecord(json)
    check("parseRecord: decodes a valid record", record != nil)
    check("parseRecord: fields", record?.command == "npm run dev" && record?.pid == 4321 && record?.shell == 900 && record?.port == 3000)
    check("parseRecord: garbage → nil", BackgroundTasks.parseRecord("not json".data(using: .utf8)!) == nil)
}

// MARK: - Status reconciliation (the heart of the monitor)

func record(status: String, exitCode: Int?, pid: Int32 = 100) -> BackgroundTaskRecord {
    BackgroundTaskRecord(id: "r", command: "cmd", pid: pid, shell: 1, log: "/tmp/r.log",
                         status: status, exitCode: exitCode, port: nil, startedAt: 0)
}

check("status: running + alive → running",
      BackgroundTasks.resolveStatus(record: record(status: "running", exitCode: nil), isAlive: true) == .running)
check("status: running + dead → failed (crash without trap)",
      BackgroundTasks.resolveStatus(record: record(status: "running", exitCode: nil), isAlive: false) == .failed)
check("status: exited + code 0 → exitedClean",
      BackgroundTasks.resolveStatus(record: record(status: "exited", exitCode: 0), isAlive: false) == .exitedClean)
check("status: exited + nil code → exitedClean",
      BackgroundTasks.resolveStatus(record: record(status: "exited", exitCode: nil), isAlive: false) == .exitedClean)
check("status: exited + code 1 → failed",
      BackgroundTasks.resolveStatus(record: record(status: "exited", exitCode: 1), isAlive: false) == .failed)
check("status: failed → failed",
      BackgroundTasks.resolveStatus(record: record(status: "failed", exitCode: 137), isAlive: false) == .failed)
check("status: an exited job's status ignores stale liveness",
      BackgroundTasks.resolveStatus(record: record(status: "exited", exitCode: 0), isAlive: true) == .exitedClean)

// MARK: - resolve() surfaces port + log

do {
    let rec = BackgroundTaskRecord(id: "s", command: "server", pid: 55, shell: 1, log: "/tmp/s.log",
                                   status: "running", exitCode: nil, port: 8080, startedAt: 0)
    let task = BackgroundTasks.resolve(record: rec, isAlive: true)
    check("resolve: carries port", task.port == 8080)
    check("resolve: carries log path", task.logPath == "/tmp/s.log")
    check("resolve: running status", task.status == .running)
}

// MARK: - Attention transition (the strip-pulse signal)

do {
    func t(_ id: String, _ s: BackgroundTaskStatus) -> BackgroundTask {
        BackgroundTask(id: id, command: id, pid: 1, status: s, port: nil, logPath: nil, startedAt: 0)
    }
    let before = [t("a", .running), t("b", .running), t("c", .failed)]
    let after = [t("a", .running), t("b", .failed), t("c", .failed)]
    let fired = BackgroundTasks.newlyFailed(previous: before, current: after)
    check("newlyFailed: reports a running→failed transition", fired == ["b"])
    check("newlyFailed: does not re-report an already-failed task", !fired.contains("c"))
    check("newlyFailed: a brand-new failed task fires",
          BackgroundTasks.newlyFailed(previous: [], current: [t("z", .failed)]) == ["z"])
    check("newlyFailed: no transition → empty",
          BackgroundTasks.newlyFailed(previous: [t("a", .running)], current: [t("a", .running)]).isEmpty)
    check("newlyFailed: a clean exit never fires",
          BackgroundTasks.newlyFailed(previous: [t("a", .running)], current: [t("a", .exitedClean)]).isEmpty)
}

// MARK: - lsof port parsing

do {
    let ipv4 = """
    COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
    node    12345 me    20u  IPv4 0x1234      0t0  TCP *:8080 (LISTEN)
    """
    check("port: *:8080 → 8080", BackgroundTasks.parseListeningPort(lsof: ipv4) == 8080)
    let bound = "python  9  me  4u  IPv4  0  0t0  TCP 127.0.0.1:3000 (LISTEN)"
    check("port: 127.0.0.1:3000 → 3000", BackgroundTasks.parseListeningPort(lsof: bound) == 3000)
    let ipv6 = "vite  7  me  8u  IPv6  0  0t0  TCP [::1]:5173 (LISTEN)"
    check("port: [::1]:5173 → 5173", BackgroundTasks.parseListeningPort(lsof: ipv6) == 5173)
    check("port: no LISTEN line → nil", BackgroundTasks.parseListeningPort(lsof: "COMMAND PID\nfoo 1") == nil)
    check("port: empty → nil", BackgroundTasks.parseListeningPort(lsof: "") == nil)
}

// MARK: - Process-subtree membership

do {
    // 900 (pane shell) → 950 (claude) → 980 (bash tool) → 1001 (the job)
    let parents: [Int32: Int32] = [1001: 980, 980: 950, 950: 900, 900: 1, 500: 1]
    check("descendant: job under pane shell", BackgroundTasks.isDescendant(1001, of: 900, in: parents))
    check("descendant: shell itself counts", BackgroundTasks.isDescendant(900, of: 900, in: parents))
    check("descendant: unrelated pid is not", !BackgroundTasks.isDescendant(500, of: 900, in: parents))
    check("descendant: missing parent chain stops", !BackgroundTasks.isDescendant(4242, of: 900, in: parents))
}

// MARK: - Incremental log tail (the "tails new log lines" behavior)

do {
    let dir = NSTemporaryDirectory() + "suit-bgtail-\(ProcessInfo.processInfo.processIdentifier)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = dir + "/log.txt"
    try? "line1\nline2\n".write(toFile: path, atomically: true, encoding: .utf8)

    guard let first = LogTail.readAppended(path: path, from: 0) else {
        check("tail: initial read", false); exit(1)
    }
    check("tail: reads the first two lines", first.lines == ["line1", "line2"])

    // Append more, including a trailing partial line (no newline yet).
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write("line3\npartial".data(using: .utf8)!)
        try? handle.close()
    }
    guard let second = LogTail.readAppended(path: path, from: first.newOffset) else {
        check("tail: append read", false); exit(1)
    }
    check("tail: reads only the new complete line", second.lines == ["line3"])
    check("tail: holds back the partial line", second.newOffset < (try! FileManager.default.attributesOfItem(atPath: path)[.size] as! UInt64))

    // Finish the partial line; the next read completes it.
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write("-done\n".data(using: .utf8)!)
        try? handle.close()
    }
    let third = LogTail.readAppended(path: path, from: second.newOffset)
    check("tail: completes the held-back line", third?.lines == ["partial-done"])

    // Truncation in place re-reads from the start.
    try? "fresh\n".write(toFile: path, atomically: true, encoding: .utf8)
    let after = LogTail.readAppended(path: path, from: 9999)
    check("tail: truncation resets to start", after?.lines == ["fresh"])

    try? FileManager.default.removeItem(atPath: dir)
}

// MARK: - Integration: real records written by scripts/suit-bg.sh

// The harness (background-tasks-test.sh) runs the real wrapper on known
// commands into $SUIT_TASKS_DIR, then invokes us with it set so we resolve the
// on-disk records against live process state — the "starts known background
// processes, asserts correct status" clause end-to-end.
if let tasksDir = ProcessInfo.processInfo.environment["SUIT_TASKS_DIR"] {
    func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
    var byMarker: [String: BackgroundTask] = [:]
    for name in (try? FileManager.default.contentsOfDirectory(atPath: tasksDir)) ?? [] where name.hasSuffix(".json") {
        guard let data = FileManager.default.contents(atPath: tasksDir + "/" + name),
              let rec = BackgroundTasks.parseRecord(data) else { continue }
        let task = BackgroundTasks.resolve(record: rec, isAlive: isAlive(rec.pid))
        // The wrapper's command string carries a unique marker word.
        for marker in ["LONGLIVED", "CLEANEXIT", "FAILEXIT"] where rec.command.contains(marker) {
            byMarker[marker] = task
        }
    }
    check("integration: long-lived job present + running",
          byMarker["LONGLIVED"]?.status == .running)
    check("integration: clean-exit job present + done",
          byMarker["CLEANEXIT"]?.status == .exitedClean)
    check("integration: failed job present + failed",
          byMarker["FAILEXIT"]?.status == .failed)
}

print(failures == 0 ? "\nAll background-task logic tests passed." : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
