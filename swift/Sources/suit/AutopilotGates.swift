import Foundation

// Autopilot gate runners (ROADMAP Phase 32): the two checks a finished run must
// pass before its PR is merged. `AutopilotBuildGate` runs the worktree's own
// build.sh; `AutopilotReviewGate` runs a headless `claude -p` review whose
// prompt arrives on **stdin** (never argv — no quoting or length hazards) and
// whose verdict is the output's final non-blank line, parsed by
// `ReviewVerdict.parse`. Both are background-queue `Process` wrappers: blocking
// work happens on a global queue, output streams into a per-attempt log file,
// a DispatchSourceTimer watchdog terminates overruns, and the completion fires
// on a background queue — the engine hops to main (generation-checked) before
// acting. Foundation-only, no AppKit: compiles standalone for logic tests.

// What a gate process did. `timedOut` and `failedToLaunch` are never conflated
// with an exit status, so the engine can message each distinctly.
enum AutopilotGateOutcome {
    case exited(Int32)           // ran to completion with this termination status
    case timedOut                // killed by the gate's watchdog
    case failedToLaunch(String)  // executable missing / unrunnable

    var cleanExit: Bool {
        if case .exited(0) = self { return true }
        return false
    }
}

// The review gate's verdict. Parse failure is `nil` — the engine treats that
// as a broken gate and blocks; ambiguity is NEVER an approve.
enum ReviewVerdict: String {
    case approve = "APPROVE"
    case reject = "REJECT"

    // Bottom-up scan for the first non-blank line; it must match
    // `^VERDICT: (APPROVE|REJECT)$` exactly (whitespace around the line is
    // tolerated, anything else on it is not). Verdict-shaped text earlier in
    // the output — quoted instructions, findings — never counts: only the
    // final non-blank line decides, per the gate prompt's contract.
    static func parse(_ output: String) -> ReviewVerdict? {
        for line in output.split(separator: "\n", omittingEmptySubsequences: false).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            switch trimmed {
            case "VERDICT: APPROVE": return .approve
            case "VERDICT: REJECT": return .reject
            default: return nil
            }
        }
        return nil
    }
}

// Gate 1 (free, runs first): `<worktree>/build.sh` with cwd = worktree,
// stdout+stderr streamed to the log file, 15-minute timeout.
enum AutopilotBuildGate {
    static let timeoutSeconds: TimeInterval = 15 * 60

    // Callable from any queue; `completion` fires on a background queue. The
    // `timeout` parameter exists for the test harness — production callers use
    // the default.
    static func run(worktree: String, logPath: String,
                    timeout: TimeInterval = AutopilotBuildGate.timeoutSeconds,
                    completion: @escaping (AutopilotGateOutcome) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            guard let log = AutopilotGateProcess.openLog(atPath: logPath) else {
                completion(.failedToLaunch("Could not create the build log at \(logPath)."))
                return
            }
            let (outcome, _) = AutopilotGateProcess.run(
                executable: worktree + "/build.sh", arguments: [], cwd: worktree,
                stdin: nil, logHandle: log, timeout: timeout, captureStdout: false)
            completion(outcome)
        }
    }
}

// Gate 2: headless `claude -p --output-format text` with cwd = worktree, the
// review prompt written to stdin, 10-minute timeout. Output goes to the log
// file *and* comes back to the caller for `ReviewVerdict.parse` / rejection
// feedback. (A headless run never refreshes claude-status.json — accepted,
// it's short; see STANDALONE.md §2.8.)
enum AutopilotReviewGate {
    static let timeoutSeconds: TimeInterval = 10 * 60

    // claude lives outside a GUI app's minimal PATH, so probe the known
    // install locations directly (mirrors GitHubCLI's gh resolution).
    // `SUIT_CLAUDE_PATH` overrides for the pipeline harness; `~` resolves from
    // the $HOME env var so tests can sandbox it. Resolved once per session.
    static let resolvedPath: String? = {
        let env = ProcessInfo.processInfo.environment
        if let override = env["SUIT_CLAUDE_PATH"], !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        let home = env["HOME"] ?? NSHomeDirectory()
        for candidate in ["/opt/homebrew/bin/claude", home + "/.local/bin/claude", home + "/.claude/local/claude"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        // Last resort: let the login shell resolve it.
        if let found = runProcess("/bin/zsh", ["-l", "-c", "command -v claude"])?
            .trimmingCharacters(in: .whitespacesAndNewlines), !found.isEmpty,
           FileManager.default.isExecutableFile(atPath: found) {
            return found
        }
        return nil
    }()

    static var isAvailable: Bool { resolvedPath != nil }

    // Callable from any queue; `completion` fires on a background queue with
    // the outcome plus the captured stdout (the verdict + findings text).
    // `model` is the Settings review model — empty/nil means claude's default.
    static func run(worktree: String, prompt: String, model: String?, logPath: String,
                    timeout: TimeInterval = AutopilotReviewGate.timeoutSeconds,
                    completion: @escaping (AutopilotGateOutcome, String) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            guard let claude = resolvedPath else {
                completion(.failedToLaunch("The claude CLI isn’t installed."), "")
                return
            }
            guard let log = AutopilotGateProcess.openLog(atPath: logPath) else {
                completion(.failedToLaunch("Could not create the review log at \(logPath)."), "")
                return
            }
            var arguments = ["-p", "--output-format", "text"]
            if let model, !model.isEmpty { arguments += ["--model", model] }
            let (outcome, output) = AutopilotGateProcess.run(
                executable: claude, arguments: arguments, cwd: worktree,
                stdin: Data(prompt.utf8), logHandle: log, timeout: timeout,
                captureStdout: true)
            completion(outcome, output)
        }
    }
}

// The shared Process plumbing: launch, stream both pipes into the log, feed
// stdin, watchdog-kill on timeout. Blocks its calling (background) thread
// until the process is done and the pipes are drained.
private enum AutopilotGateProcess {
    // Creates the log file (and its logs/<slug>/ parent) truncated, ready for
    // appending stream chunks. Nil when the path isn't writable.
    static func openLog(atPath path: String) -> FileHandle? {
        let manager = FileManager.default
        try? manager.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                     withIntermediateDirectories: true)
        manager.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }

    static func run(executable: String, arguments: [String], cwd: String,
                    stdin stdinData: Data?, logHandle: FileHandle,
                    timeout: TimeInterval, captureStdout: Bool) -> (AutopilotGateOutcome, String) {
        defer { try? logHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let stdinPipe: Pipe? = stdinData == nil ? nil : Pipe()
        if let stdinPipe { process.standardInput = stdinPipe }

        // One serial queue orders the interleaved stdout/stderr log writes and
        // guards the capture buffer + timed-out flag.
        let ioQueue = DispatchQueue(label: "suit.autopilot.gate-io")
        var captured = Data()
        var timedOut = false

        // readabilityHandlers deliver chunks until an empty read marks EOF;
        // the group tracks both pipes so we never report completion with tail
        // output still in flight.
        let drained = DispatchGroup()
        stream(stdout, group: drained) { data in
            ioQueue.async {
                logHandle.write(data)
                if captureStdout { captured.append(data) }
            }
        }
        stream(stderr, group: drained) { data in
            ioQueue.async { logHandle.write(data) }
        }

        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            return (.failedToLaunch(error.localizedDescription), "")
        }

        // Feed stdin off-thread — a review prompt is far bigger than the 64 KB
        // pipe buffer, so a synchronous write before the child reads would
        // deadlock — then close so the child sees EOF.
        if let stdinPipe, let stdinData {
            DispatchQueue.global(qos: .utility).async {
                writeAll(stdinData, to: stdinPipe.fileHandleForWriting)
            }
        }

        // Watchdog: SIGTERM at the deadline, SIGKILL 10 s later if the process
        // ignored it (waitUntilExit would otherwise hang forever).
        let pid = process.processIdentifier
        let watchdog = DispatchSource.makeTimerSource(queue: ioQueue)
        watchdog.schedule(deadline: .now() + timeout)
        watchdog.setEventHandler {
            guard process.isRunning else { return }
            timedOut = true
            process.terminate()
            ioQueue.asyncAfter(deadline: .now() + 10) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
        watchdog.resume()

        process.waitUntilExit()
        watchdog.cancel()
        // A stray grandchild holding the pipe open must not wedge the gate:
        // give the streams a few seconds to hit EOF, then move on.
        _ = drained.wait(timeout: .now() + 5)
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil

        var result: (AutopilotGateOutcome, String) = (.exited(0), "")
        ioQueue.sync {  // serial queue ⇒ every queued log/capture write has landed
            let outcome: AutopilotGateOutcome = timedOut ? .timedOut : .exited(process.terminationStatus)
            result = (outcome, captureStdout ? String(decoding: captured, as: UTF8.self) : "")
        }
        return result
    }

    private static func stream(_ pipe: Pipe, group: DispatchGroup, _ sink: @escaping (Data) -> Void) {
        group.enter()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                group.leave()
            } else {
                sink(data)
            }
        }
    }

    // POSIX write loop with per-fd SIGPIPE suppression: a child that dies
    // before reading its stdin must not SIGPIPE the whole app (FileHandle's
    // write would raise an uncatchable ObjC exception on the broken pipe).
    private static func writeAll(_ data: Data, to handle: FileHandle) {
        let fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = write(fd, base + offset, raw.count - offset)
                if written < 0 && errno == EINTR { continue }
                if written <= 0 { break }
                offset += written
            }
        }
        try? handle.close()
    }
}
