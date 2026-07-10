import Cocoa

// Checkpoint / rewind timeline. Claude Code automatically
// saves a code snapshot before each change (the thing /rewind and Esc-Esc roll
// back to). It records them in the session's JSONL transcript as
// `file-history-snapshot` entries — each lists which files it backed up and to
// which version — with the backup content living at
// ~/.claude/file-history/<session-id>/<name>@vN.
//
// This pane reads that history and renders it as a read-only, live-tailing
// timeline. It's viewer-first: you scrub the change history and open any file
// *as it was* at a checkpoint, instead of typing /rewind blind and guessing.
// Rolling back itself stays Claude's job — "Rewind in session" injects /rewind
// so its native picker opens in the pane. (A non-interactive `/rewind <ref>`
// form would let us restore one specific node in a single click; whether that
// exists remains an open question — the *history* is
// readable, which is what this pane needed.)

// MARK: - Parsing

// One backed-up file within a checkpoint.
struct CheckpointFile: Equatable {
    let path: String            // path Claude reported (usually repo-relative)
    let version: Int
    let backupFileName: String  // "<hash>@vN" under file-history/<session-id>/
}

// One checkpoint: a single `file-history-snapshot` transcript entry.
struct Checkpoint: Equatable {
    let messageId: String
    let time: Date?
    let files: [CheckpointFile]
    let promptSummary: String   // nearest preceding user prompt, for context
}

// A transcript line is one of three things we care about while building the
// timeline: a user prompt (so the next checkpoint can name what triggered it),
// a checkpoint entry, or noise. Free functions so they're testable headless.
enum CheckpointLine: Equatable {
    case prompt(String)
    case checkpoint(messageId: String, time: Date?, files: [CheckpointFile])
}

private let checkpointDateParser: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private func parseCheckpointTime(_ value: Any?) -> Date? {
    guard let string = value as? String, !string.isEmpty else { return nil }
    return checkpointDateParser.date(from: string)
        ?? ISO8601DateFormatter().date(from: string)
}

func parseCheckpointLine(_ line: String) -> CheckpointLine? {
    guard let data = line.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let type = object["type"] as? String else { return nil }

    if type == "file-history-snapshot" {
        // The snapshot payload carries the timestamp and the backed-up files.
        let snapshot = object["snapshot"] as? [String: Any]
        let messageId = (object["messageId"] as? String)
            ?? (snapshot?["messageId"] as? String) ?? ""
        let time = parseCheckpointTime(snapshot?["timestamp"])
        var files: [CheckpointFile] = []
        // trackedFileBackups: { "<path>": { backupFileName, version, backupTime } }
        for (path, raw) in (snapshot?["trackedFileBackups"] as? [String: Any] ?? [:]) {
            guard let backup = raw as? [String: Any],
                  let name = backup["backupFileName"] as? String else { continue }
            let version = (backup["version"] as? Int)
                ?? Int(name.split(separator: "v").last ?? "") ?? 0
            files.append(CheckpointFile(path: path, version: version, backupFileName: name))
        }
        files.sort { $0.path < $1.path }
        // A snapshot with no backed-up files is bookkeeping, not a checkpoint.
        guard !files.isEmpty else { return nil }
        return .checkpoint(messageId: messageId, time: time, files: files)
    }

    // Track real user prompts so a checkpoint can show what asked for it. Same
    // filtering as the transcript pane: plain-string content, no tag-shaped
    // synthetic prompts, no tool_result arrays.
    if type == "user", let message = object["message"] as? [String: Any],
       let text = message["content"] as? String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !trimmed.hasPrefix("<") {
            return .prompt(trimmed)
        }
    }
    return nil
}

// MARK: - Text view

// Mirrors TranscriptTextView: a back-pointer for pane-scoped actions; focus
// visuals are derived by the window controller, not reported from here.
final class CheckpointTextView: NSTextView {
    weak var timelineContent: CheckpointTimelinePaneContent?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let copyItem = menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        copyItem.isEnabled = selectedRange().length > 0
        return menu
    }
}

// MARK: - Pane content

final class CheckpointTimelinePaneContent: NSObject, PaneContent, NSTextViewDelegate {
    weak var pane: Pane?
    weak var tab: Tab?

    private let scrollView = NSScrollView(frame: .zero)
    private let textView: CheckpointTextView

    private(set) var transcriptPath: String?
    private var sessionId: String?
    private var sessionCwd: String?
    private var sessionTitle: String?

    private var checkpoints: [Checkpoint] = []
    private var lastPrompt: String = ""

    // Live-tail state, identical in shape to the transcript pane's.
    private var readOffset: UInt64 = 0
    private var remainder = Data()
    private var watchSource: DispatchSourceFileSystemObject?

    private var font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
    private var baseTextColor: NSColor = .textColor

    private static let maxCheckpoints = 2000

    var view: NSView { scrollView }
    var focusTarget: NSView { textView }
    var defaultTitle: String { "Checkpoints" }
    var workingDirectory: String? { sessionCwd }

    override init() {
        textView = CheckpointTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.drawsBackground = true

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        super.init()
        textView.timelineContent = self
        textView.delegate = self
        textView.linkTextAttributes = [
            .foregroundColor: Theme.accent,
            .cursor: NSCursor.pointingHand,
        ]
    }

    // MARK: Loading + live tail

    func load(session: ClaudeSession) {
        sessionId = session.id
        sessionCwd = session.cwd
        sessionTitle = session.displayName
        tab?.contentTitleDidChange("Checkpoints — \(session.displayName)")

        stopWatching()
        checkpoints = []
        lastPrompt = ""
        readOffset = 0
        remainder = Data()

        guard let path = session.transcriptPath, FileManager.default.fileExists(atPath: path) else {
            transcriptPath = nil
            textView.string = session.transcriptPath == nil
                ? "No checkpoints recorded for this session yet.\n(Checkpoints are read from the session transcript; older sessions predate the transcript_path integration and new activity will fill it in.)"
                : "Transcript file not found:\n\(session.transcriptPath ?? "")"
            return
        }
        transcriptPath = path
        readAppended()
        watch(path: path)
        render()
    }

    private func watch(path: String) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if source.data.contains(.delete) || source.data.contains(.rename) {
                self.stopWatching()
                self.checkpoints = []
                self.lastPrompt = ""
                self.readOffset = 0
                self.remainder = Data()
                if FileManager.default.fileExists(atPath: path) {
                    self.readAppended()
                    self.watch(path: path)
                }
                self.render()
                return
            }
            self.readAppended()
            self.render()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watchSource = source
    }

    private func stopWatching() {
        watchSource?.cancel()
        watchSource = nil
    }

    // Reads everything past readOffset and folds complete lines into the
    // checkpoint list; a write can land mid-line, so the tail fragment waits in
    // `remainder`. Unlike the transcript pane we always re-render (the graph's
    // node numbering depends on the whole list), which is cheap at this scale.
    private func readAppended() {
        guard let transcriptPath, let handle = FileHandle(forReadingAtPath: transcriptPath) else { return }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        if size < readOffset {
            checkpoints = []
            lastPrompt = ""
            readOffset = 0
            remainder = Data()
        }
        guard size > readOffset else { return }
        try? handle.seek(toOffset: readOffset)
        guard let data = try? handle.readToEnd() else { return }
        readOffset = size

        var buffer = remainder
        buffer.append(data)
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer = buffer[buffer.index(after: newline)...]
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            switch parseCheckpointLine(line) {
            case .prompt(let text):
                lastPrompt = text
            case .checkpoint(let messageId, let time, let files):
                checkpoints.append(Checkpoint(messageId: messageId, time: time, files: files, promptSummary: lastPrompt))
            case nil:
                break
            }
        }
        remainder = Data(buffer)
        if checkpoints.count > Self.maxCheckpoints {
            checkpoints.removeFirst(checkpoints.count - Self.maxCheckpoints)
        }
    }

    // MARK: Rendering

    private lazy var timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d · HH:mm:ss"
        return f
    }()

    private func render() {
        let wasAtBottom = isAtBottom
        textView.textStorage?.setAttributedString(attributedTimeline())
        if wasAtBottom { textView.scrollToEndOfDocument(nil) }
    }

    private var isAtBottom: Bool {
        let visible = scrollView.contentView.bounds
        return visible.maxY >= textView.frame.maxY - 40
    }

    private func attributedTimeline() -> NSAttributedString {
        let result = NSMutableAttributedString()
        let boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 2
        paragraph.lineSpacing = 1

        // Header: the rewind action (only meaningful when a live pane hosts the
        // session's pty — otherwise there's nothing to inject into).
        let canRewind = sessionId.flatMap {
            (NSApp.delegate as? AppDelegate)?.terminalContent(forSessionId: $0)
        } != nil
        let header = NSMutableAttributedString()
        if canRewind {
            header.append(NSAttributedString(string: "↺ Rewind in session…", attributes: [
                .font: boldFont, .link: "rewind", .paragraphStyle: paragraph,
            ]))
            header.append(NSAttributedString(string: "   opens Claude's /rewind picker in the pane\n\n", attributes: [
                .font: font, .foregroundColor: Theme.textDim, .paragraphStyle: paragraph,
            ]))
        }
        result.append(header)

        if checkpoints.isEmpty {
            result.append(NSAttributedString(string: "No checkpoints yet — they appear here as Claude changes files.", attributes: [
                .font: font, .foregroundColor: Theme.textDim, .paragraphStyle: paragraph,
            ]))
            return result
        }

        // Newest first reads like a history you scan from the top.
        let nodeParagraph = NSMutableParagraphStyle()
        nodeParagraph.paragraphSpacing = 1
        for (offset, checkpoint) in checkpoints.enumerated().reversed() {
            let number = offset + 1
            let time = checkpoint.time.map(timeFormatter.string) ?? "—"
            let node = "◉  #\(number)   \(time)"
            result.append(NSAttributedString(string: node, attributes: [
                .font: boldFont, .foregroundColor: Theme.accent, .paragraphStyle: nodeParagraph,
            ]))
            result.append(NSAttributedString(string: "\n", attributes: [.font: font]))

            if !checkpoint.promptSummary.isEmpty {
                let summary = checkpoint.promptSummary.replacingOccurrences(of: "\n", with: " ")
                let clipped = summary.count > 100 ? String(summary.prefix(100)) + "…" : summary
                result.append(NSAttributedString(string: "│  “\(clipped)”\n", attributes: [
                    .font: font, .foregroundColor: baseTextColor, .paragraphStyle: nodeParagraph,
                ]))
            }
            for file in checkpoint.files {
                // Each file is a link that opens that backed-up version in a viewer.
                let payload = "snapshot|\(file.backupFileName)|\(file.path)"
                let line = NSMutableAttributedString(string: "│    ↳ ", attributes: [
                    .font: font, .foregroundColor: Theme.textDim, .paragraphStyle: nodeParagraph,
                ])
                line.append(NSAttributedString(string: "\(file.path) · v\(file.version)", attributes: [
                    .font: font, .link: payload, .paragraphStyle: nodeParagraph,
                ]))
                result.append(line)
                result.append(NSAttributedString(string: "\n", attributes: [.font: font]))
            }
            result.append(NSAttributedString(string: "│\n", attributes: [
                .font: font, .foregroundColor: Theme.textFaint, .paragraphStyle: nodeParagraph,
            ]))
        }
        return result
    }

    // MARK: Links

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let payload = link as? String else { return false }
        if payload == "rewind" {
            if let sessionId {
                (NSApp.delegate as? AppDelegate)?.rewindSession(withId: sessionId)
            }
            return true
        }
        let parts = payload.components(separatedBy: "|")
        if parts.count == 3, parts[0] == "snapshot" {
            openSnapshot(backupFileName: parts[1], originalPath: parts[2])
            return true
        }
        return false
    }

    // Reads the backed-up file content and drops it in a temp file named after
    // the original (so the viewer titles and syntax-highlights it sensibly),
    // then opens it read-only through the same plumbing as any file link.
    private func openSnapshot(backupFileName: String, originalPath: String) {
        guard let sessionId else { return }
        let source = NSHomeDirectory() + "/.claude/file-history/" + sessionId + "/" + backupFileName
        guard let data = FileManager.default.contents(atPath: source) else {
            NSSound.beep()
            return
        }
        let dir = NSTemporaryDirectory() + "suit-checkpoints"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let base = (originalPath as NSString).lastPathComponent
        let stem = (base as NSString).deletingPathExtension
        let ext = (base as NSString).pathExtension
        let version = backupFileName.contains("@v") ? "@v" + (backupFileName.components(separatedBy: "@v").last ?? "") : ""
        let name = ext.isEmpty ? "\(stem)\(version)" : "\(stem)\(version).\(ext)"
        let target = dir + "/" + name
        do {
            try data.write(to: URL(fileURLWithPath: target))
        } catch {
            NSSound.beep()
            return
        }
        pane?.openFileLink(path: target, line: nil)
    }

    // MARK: Appearance

    func applyFont(_ newFont: NSFont) {
        font = newFont
        render()
    }

    func applyTextColor(_ color: NSColor) {
        baseTextColor = color
        render()
    }

    func applyBackground(_ color: NSColor) {
        textView.backgroundColor = color
    }

    func teardown() {
        stopWatching()
    }
}
