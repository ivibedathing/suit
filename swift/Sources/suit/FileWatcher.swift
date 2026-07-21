import Foundation

// Watches one file path and calls back on the main thread when it changes —
// the Cocoa half of FileWatch.swift, which owns the decisions this executes.
//
// The DispatchSource pattern is the one TranscriptPane+Tail and
// CheckpointTimeline already use, generalised so the four file-backed panes
// (viewer, markdown, image, PDF) share one implementation instead of a fourth
// copy. Two things it does that a naive watcher doesn't:
//
//  * **Re-opens the path after an atomic replace.** O_EVTONLY watches an inode,
//    not a name. Data.write(.atomic), git and most editors rename a temp file
//    over the target, so after the first such write our descriptor refers to an
//    unlinked inode and would never fire again. delete/rename therefore means
//    "re-open the path", on a short backoff because the path is briefly absent
//    mid-replace.
//  * **Coalesces bursts.** A generator that writes a file in chunks would
//    otherwise cost one reload per chunk; events inside FileWatchPolicy's
//    window collapse into a single callback.
//
// The callback is fired on the main queue and must capture its owner weakly —
// the watcher retains it, and the owner retains the watcher.
final class FileWatcher {
    private let path: String
    private let onChange: () -> Void

    private var source: DispatchSourceFileSystemObject?
    private var descriptor: Int32 = -1
    private var coalesceTimer: Timer?
    private var rearmTimer: Timer?
    private var rearmAttempt = 0
    private var stopped = false
    // Set when a re-open attempt found nothing at the path. While that's true we
    // are deaf: the file can be recreated without producing an event, because we
    // weren't watching anything when it happened. So a re-open that finally
    // succeeds has to report a change itself — otherwise a `git checkout` that
    // deletes and rewrites the file leaves the pane showing the old content
    // forever. (The ordinary atomic-replace path re-opens on the first attempt
    // and reports the change directly, so this only covers real absence.)
    private var missedChangeWhileDetached = false

    // `path` should already be standardized — the watcher compares nothing, it
    // just opens what it's given.
    init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
        arm()
    }

    deinit { stop() }

    // Idempotent and terminal: a stopped watcher stays stopped, so loading a
    // different file means dropping this one and constructing a new watcher
    // rather than re-pointing it. Panes call it from teardown() and before each
    // load, which is safe to do twice (PaneContent.teardown's contract).
    func stop() {
        stopped = true
        coalesceTimer?.invalidate(); coalesceTimer = nil
        rearmTimer?.invalidate(); rearmTimer = nil
        // The cancel handler closes the descriptor; clearing it here keeps a
        // second stop() from double-closing (and closing someone else's fd that
        // reused the number).
        source?.cancel()
        source = nil
        descriptor = -1
    }

    // MARK: - Descriptor lifecycle

    private func arm() {
        guard !stopped else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            // Mid-atomic-replace, or genuinely gone. Retry on the backoff.
            missedChangeWhileDetached = true
            scheduleRearm()
            return
        }
        rearmAttempt = 0
        descriptor = fd
        if missedChangeWhileDetached {
            missedChangeWhileDetached = false
            scheduleNotify()
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .revoke], queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            self.handle(source.data)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    private func handle(_ raw: DispatchSource.FileSystemEvent) {
        guard !stopped else { return }
        var events: FileWatchEvents = []
        if raw.contains(.write)  { events.insert(.write) }
        if raw.contains(.extend) { events.insert(.extend) }
        if raw.contains(.delete) { events.insert(.delete) }
        if raw.contains(.rename) { events.insert(.rename) }
        if raw.contains(.revoke) { events.insert(.revoke) }

        switch FileWatchPolicy.action(for: events) {
        case .reread:
            scheduleNotify()
        case .rearm:
            // The descriptor is dead: drop it, re-open the path, and report the
            // change — an atomic replace *is* the edit we're watching for.
            source?.cancel()
            source = nil
            descriptor = -1
            rearmAttempt = 0
            scheduleRearm()
            scheduleNotify()
        }
    }

    private func scheduleRearm() {
        guard !stopped else { return }
        guard let delay = FileWatchPolicy.rearmDelay(attempt: rearmAttempt) else {
            // The file has stayed gone across the whole backoff. Stop rather
            // than keep a timer alive behind a tab nobody may ever look at; the
            // viewer's app-activation reconcile still catches it coming back.
            return
        }
        rearmAttempt += 1
        rearmTimer?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.arm()
        }
        rearmTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: - Callback

    private func scheduleNotify() {
        coalesceTimer?.invalidate()
        let timer = Timer(timeInterval: FileWatchPolicy.coalesceInterval, repeats: false) { [weak self] _ in
            guard let self, !self.stopped else { return }
            self.onChange()
        }
        coalesceTimer = timer
        // .common, not the default mode: the reload should land while a menu is
        // open or the user is mid-scroll, not sit queued until the tracking loop
        // ends.
        RunLoop.main.add(timer, forMode: .common)
    }
}
