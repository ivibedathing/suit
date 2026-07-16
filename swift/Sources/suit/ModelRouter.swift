import Foundation

// Model routing, IO half: the one place that actually asks Haiku which tier a
// request deserves. ModelRouting.swift holds the pure logic (prompt, parsing,
// heuristic) and is harness-tested standalone; everything that touches a
// process lives here.
//
// Shape note: this deliberately does not reuse AutopilotGateProcess. That
// plumbing exists for 10-minute review runs — it streams both pipes into a log
// file, feeds multi-KB stdin off-thread to dodge a pipe deadlock, and takes a
// cancellation handle. A classifier call is the opposite shape: a few KB in,
// one word out, seconds long, nothing worth logging. It does reuse
// AutopilotReviewGate.resolvedPath, because binary resolution is the part
// that's genuinely hard (a GUI app's PATH doesn't contain claude) and should
// have exactly one implementation.
enum ModelRouter {
    // Generous for a one-word answer, but the call competes with whatever else
    // the machine is doing and a timeout costs us the classifier entirely
    // (we fall back to the heuristic). Spawning already waits on a full
    // `git worktree add` checkout, so this is not the slow part of a run.
    static let timeoutSeconds: TimeInterval = 20

    static var isAvailable: Bool { AutopilotReviewGate.resolvedPath != nil }

    // Blocking — call from a background queue only. Returns nil for every
    // failure (no binary, launch failure, timeout, non-zero exit, unparseable
    // output); every nil means "use the heuristic", never "block the run".
    // Routing is advisory: it can make a run cheaper, never make it fail.
    static func classify(request: String, cwd: String) -> ModelTier? {
        guard let claude = AutopilotReviewGate.resolvedPath else { return nil }
        guard let output = run(claude: claude,
                              prompt: ModelRouting.classifierPrompt(for: request),
                              cwd: cwd) else { return nil }
        return ModelRouting.parse(output)
    }

    private static func run(claude: String, prompt: String, cwd: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = ["-p", "--output-format", "text",
                             "--model", ModelTier.haiku.rawValue]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)

        let stdout = Pipe()
        let stdin = Pipe()
        process.standardOutput = stdout
        process.standardInput = stdin
        // Discarded rather than drained: nothing here is worth logging, and a
        // null device can't fill up and wedge the child the way an unread pipe
        // could.
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // Safe to write synchronously: ModelRouting caps the request at 6k
        // characters, so the whole prompt is well under the 64 KB pipe buffer
        // and this returns without waiting for the child to read. The review
        // gate needs an off-thread write because its prompt embeds a full diff;
        // this one can't get near that size.
        stdin.fileHandleForWriting.write(Data(prompt.utf8))
        try? stdin.fileHandleForWriting.close()

        // Watchdog: terminate() closes the child's stdout, which unblocks the
        // readDataToEndOfFile below — so a hung classifier can't hang a spawn.
        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + timeoutSeconds, execute: watchdog)

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        // A terminated (timed-out) child lands here too, with a non-zero
        // status — no separate timeout branch needed.
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
