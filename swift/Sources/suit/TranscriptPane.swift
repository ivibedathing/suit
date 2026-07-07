import Cocoa

// Claude transcript pane (ROADMAP Phase 7): renders a session's JSONL
// transcript — the conversation itself, not the terminal's scrollback — and
// live-tails it while Claude works. Read-only, like the file viewer: what
// Claude *did* (prompts, replies, tool calls) at a glance, with file paths
// clickable into the viewer pane.

// MARK: - Transcript parsing

// One rendered item of the conversation. Tool calls collapse to a single
// summary line; thinking blocks, sidechain (subagent) traffic, and transcript
// bookkeeping entries (mode, file-history-snapshot, attachment, …) are
// dropped entirely.
enum TranscriptEntry: Equatable {
    case user(String)
    case assistantText(String)
    case toolUse(name: String, summary: String)

    // The searchable / snippet text of an entry, independent of its rendered
    // decoration (used by cross-transcript search — Phase 20 — and the pane's
    // jump anchoring).
    var plainText: String {
        switch self {
        case .user(let text): return text
        case .assistantText(let text): return text
        case .toolUse(let name, let summary): return summary.isEmpty ? name : "\(name) — \(summary)"
        }
    }
}

// A single JSONL line can carry several content blocks (one assistant message
// interleaves text and tool_use), so parsing returns zero or more entries.
// Free function so it's testable without a pane.
func parseTranscriptLine(_ line: String) -> [TranscriptEntry] {
    guard let data = line.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let type = object["type"] as? String else { return [] }
    // Subagent conversations share the file but aren't this session's thread.
    if object["isSidechain"] as? Bool == true { return [] }
    guard type == "user" || type == "assistant",
          let message = object["message"] as? [String: Any] else { return [] }

    if type == "user" {
        // Real prompts are plain strings; array content is tool_result plumbing.
        // Skip slash-command wrappers (<command-name>…) and other tag-shaped
        // synthetic prompts.
        guard let text = message["content"] as? String else { return [] }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<") else { return [] }
        return [.user(trimmed)]
    }

    var entries: [TranscriptEntry] = []
    for case let block as [String: Any] in message["content"] as? [Any] ?? [] {
        switch block["type"] as? String {
        case "text":
            if let text = (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                entries.append(.assistantText(text))
            }
        case "tool_use":
            let name = block["name"] as? String ?? "tool"
            entries.append(.toolUse(name: name, summary: toolSummary(input: block["input"] as? [String: Any])))
        default:
            break // thinking, images, …
        }
    }
    return entries
}

// The one input field worth showing for a collapsed tool call, by usefulness:
// a path beats a command beats a free-text description.
private func toolSummary(input: [String: Any]?) -> String {
    guard let input else { return "" }
    for key in ["file_path", "path", "command", "pattern", "query", "prompt", "description", "skill", "name", "url"] {
        if let value = input[key] as? String, !value.isEmpty {
            let flat = value.replacingOccurrences(of: "\n", with: " ")
            return flat.count > 120 ? String(flat.prefix(120)) + "…" : flat
        }
    }
    return ""
}

// Same resolution rules as the terminal's Cmd-click links (PaneTerminalView.
// resolveFileLink), but against an explicit base directory since a transcript
// pane has no shell: strip a trailing :line[:col], try absolute then
// cwd-relative, and only accept paths that exist as regular files.
func resolveFileReference(_ link: String, relativeTo cwd: String?) -> (path: String, line: Int?)? {
    guard !link.contains("://"), !link.hasPrefix("mailto:") else { return nil }

    var parts = link.components(separatedBy: ":")
    var numbers: [Int] = []
    while parts.count > 1, numbers.count < 2, let n = Int(parts.last ?? ""), n > 0 {
        numbers.insert(n, at: 0)
        parts.removeLast()
    }
    let line = numbers.first

    for (candidate, candidateLine) in [(parts.joined(separator: ":"), line), (link, nil)] {
        let expanded = (candidate as NSString).expandingTildeInPath
        let absolute: String
        if expanded.hasPrefix("/") {
            absolute = expanded
        } else if let cwd {
            absolute = cwd + "/" + expanded
        } else {
            continue
        }
        let standardized = (absolute as NSString).standardizingPath
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: standardized, isDirectory: &isDirectory), !isDirectory.boolValue {
            return (standardized, candidateLine)
        }
    }
    return nil
}

// MARK: - Text view

// Mirrors ViewerTextView: content backpointer for pane-scoped actions; focus
// visuals are derived by the window controller, not reported from here.
final class TranscriptTextView: NSTextView {
    weak var transcriptContent: TranscriptPaneContent?

    // ROADMAP Phase 18 — send the selection into a Claude session as a `/goal`.
    @objc func setAsGoal(_ sender: Any?) {
        transcriptContent?.setSelectionAsGoal()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let copyItem = menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        copyItem.isEnabled = selectedRange().length > 0
        let goalItem = menu.addItem(withTitle: "Set as Goal", action: #selector(setAsGoal(_:)), keyEquivalent: "")
        goalItem.isEnabled = selectedRange().length > 0
        return menu
    }
}

// MARK: - Pane content

final class TranscriptPaneContent: NSObject, PaneContent, NSTextViewDelegate {
    weak var pane: Pane?
    weak var tab: Tab?

    private let scrollView = NSScrollView(frame: .zero)
    private let textView: TranscriptTextView

    private(set) var transcriptPath: String?
    private var sessionCwd: String?
    private var sessionTitle: String?

    private var entries: [TranscriptEntry] = []
    // The 1-based source-file line each entry was parsed from, parallel to
    // `entries` — lets cross-transcript search jump the pane to a matching line
    // (Phase 20). `lineCounter` counts every complete line read, entry-producing
    // or not, so it tracks the file's real line numbers (what ripgrep reports).
    private var entrySourceLines: [Int] = []
    private var lineCounter = 0
    // Char offset (into the rendered text) of each entry, parallel to `entries`;
    // recomputed by a full render(), consumed by jump(toSourceLine:).
    private var entryCharStarts: [Int] = []
    // Which entry the last jump anchored on (nil if none) — the anchor visible
    // to the harness/verification.
    private(set) var anchoredEntryIndex: Int?
    // Live-tail state: how far into the file we've parsed, plus any trailing
    // partial line the last read stopped in the middle of.
    private var readOffset: UInt64 = 0
    private var remainder = Data()
    private var watchSource: DispatchSourceFileSystemObject?

    private var font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
    private var baseTextColor: NSColor = .textColor

    // A runaway transcript stops being a conversation view and starts being a
    // memory problem; keep the most recent slice.
    private static let maxEntries = 4000

    var view: NSView { scrollView }
    var focusTarget: NSView { textView }
    var defaultTitle: String { "Transcript" }
    var workingDirectory: String? { sessionCwd }

    override init() {
        textView = TranscriptTextView(frame: .zero)
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
        textView.transcriptContent = self
        textView.delegate = self
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
    }

    // MARK: Loading + live tail

    func load(session: ClaudeSession) {
        load(path: session.transcriptPath, cwd: session.cwd, title: session.displayName)
    }

    // Path-based load — the same viewer, driven by an explicit transcript file
    // rather than a live session (cross-transcript search opens historical
    // sessions this way; Phase 20).
    func load(path: String?, cwd: String?, title: String) {
        sessionCwd = cwd
        sessionTitle = title
        tab?.contentTitleDidChange("Transcript — \(title)")

        stopWatching()
        entries = []
        entrySourceLines = []
        lineCounter = 0
        entryCharStarts = []
        anchoredEntryIndex = nil
        readOffset = 0
        remainder = Data()

        guard let path, FileManager.default.fileExists(atPath: path) else {
            transcriptPath = nil
            textView.string = path == nil
                ? "No transcript recorded for this session yet.\n(Older sessions predate the transcript_path integration — new activity in the session will fill it in.)"
                : "Transcript file not found:\n\(path ?? "")"
            return
        }
        transcriptPath = path
        readAppended()
        watch(path: path)
        textView.scrollToEndOfDocument(nil)
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
                // Recreated file (e.g. session resumed): start over if it's back.
                self.stopWatching()
                self.entries = []
                self.entrySourceLines = []
                self.lineCounter = 0
                self.readOffset = 0
                self.remainder = Data()
                if FileManager.default.fileExists(atPath: path) {
                    self.readAppended()
                    self.watch(path: path)
                    self.render()
                }
                return
            }
            self.readAppended()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watchSource = source
    }

    private func stopWatching() {
        watchSource?.cancel()
        watchSource = nil
    }

    // Reads everything past readOffset, parses complete lines (a write can land
    // mid-line; the tail fragment waits in `remainder` for the next event), and
    // appends the new entries.
    private func readAppended() {
        guard let transcriptPath, let handle = FileHandle(forReadingAtPath: transcriptPath) else { return }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        if size < readOffset {
            // Truncated in place: start over.
            entries = []
            entrySourceLines = []
            lineCounter = 0
            readOffset = 0
            remainder = Data()
        }
        guard size > readOffset else { return }
        try? handle.seek(toOffset: readOffset)
        guard let data = try? handle.readToEnd() else { return }
        readOffset = size

        var buffer = remainder
        buffer.append(data)
        var newEntries: [TranscriptEntry] = []
        var newSourceLines: [Int] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer = buffer[buffer.index(after: newline)...]
            lineCounter += 1
            if let line = String(data: lineData, encoding: .utf8) {
                let parsed = parseTranscriptLine(line)
                newEntries.append(contentsOf: parsed)
                newSourceLines.append(contentsOf: Array(repeating: lineCounter, count: parsed.count))
            }
        }
        remainder = Data(buffer)

        guard !newEntries.isEmpty else { return }
        entries.append(contentsOf: newEntries)
        entrySourceLines.append(contentsOf: newSourceLines)
        if entries.count > Self.maxEntries {
            let drop = entries.count - Self.maxEntries
            entries.removeFirst(drop)
            entrySourceLines.removeFirst(drop)
            render()
        } else {
            append(attributed: attributedString(for: newEntries))
        }
    }

    // MARK: Rendering

    private func render() {
        let wasAtBottom = isAtBottom
        let (text, starts) = buildAttributed(entries)
        entryCharStarts = starts
        textView.textStorage?.setAttributedString(text)
        if wasAtBottom {
            textView.scrollToEndOfDocument(nil)
        }
    }

    // Scrolls the pane to the entry parsed from (or nearest after) a given
    // source-file line and flashes it — how cross-transcript search anchors a
    // clicked result (Phase 20). Rebuilds the full document first so the
    // recorded char offsets line up with what's on screen.
    func jump(toSourceLine line: Int) {
        render()
        guard !entries.isEmpty else { anchoredEntryIndex = nil; return }
        let idx: Int
        if let exact = entrySourceLines.firstIndex(of: line) {
            idx = exact
        } else if let after = entrySourceLines.firstIndex(where: { $0 >= line }) {
            idx = after
        } else {
            idx = entries.count - 1
        }
        anchoredEntryIndex = idx
        guard idx < entryCharStarts.count else { return }
        let start = entryCharStarts[idx]
        let end = idx + 1 < entryCharStarts.count ? entryCharStarts[idx + 1] : (textView.string as NSString).length
        let range = NSRange(location: start, length: max(0, end - start))

        textView.setSelectedRange(NSRange(location: start, length: 0))
        textView.scrollRangeToVisible(range)

        // Brief highlight so the eye lands on the anchored entry (temporary
        // attributes never touch the document), mirroring the viewer's jump.
        guard let layoutManager = textView.layoutManager else { return }
        layoutManager.addTemporaryAttribute(
            .backgroundColor, value: Theme.accent.withAlphaComponent(0.3), forCharacterRange: range
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak layoutManager] in
            layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
        }
    }

    // The text of the entry the last jump landed on — the harness's assertion
    // hook for "clicking anchors the transcript pane to the matching line."
    var anchoredEntryText: String? {
        guard let idx = anchoredEntryIndex, entries.indices.contains(idx) else { return nil }
        return entries[idx].plainText
    }

    private func append(attributed: NSAttributedString) {
        let wasAtBottom = isAtBottom
        textView.textStorage?.append(attributed)
        if wasAtBottom {
            textView.scrollToEndOfDocument(nil)
        }
    }

    // Auto-follow only while the user is already reading the tail; scrolled-up
    // reading positions are never yanked away.
    private var isAtBottom: Bool {
        let visible = scrollView.contentView.bounds
        return visible.maxY >= textView.frame.maxY - 40
    }

    private func attributedString(for entries: [TranscriptEntry]) -> NSAttributedString {
        buildAttributed(entries).text
    }

    // Renders entries, recording each entry's starting character offset (so a
    // full render can map an entry back to a scrollable range for jumps).
    private func buildAttributed(_ entries: [TranscriptEntry]) -> (text: NSAttributedString, starts: [Int]) {
        let result = NSMutableAttributedString()
        var starts: [Int] = []
        let boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 6

        for entry in entries {
            starts.append(result.length)
            switch entry {
            case .user(let text):
                result.append(NSAttributedString(string: "❯ ", attributes: [
                    .font: boldFont, .foregroundColor: Theme.accent, .paragraphStyle: paragraph,
                ]))
                result.append(linkified(text, attributes: [
                    .font: boldFont, .foregroundColor: baseTextColor, .paragraphStyle: paragraph,
                ]))
            case .assistantText(let text):
                result.append(linkified(text, attributes: [
                    .font: font, .foregroundColor: baseTextColor, .paragraphStyle: paragraph,
                ]))
            case .toolUse(let name, let summary):
                let label = summary.isEmpty ? "⏺ \(name)" : "⏺ \(name) — \(summary)"
                result.append(linkified(label, attributes: [
                    .font: font, .foregroundColor: Theme.textDim, .paragraphStyle: paragraph,
                ]))
            }
            result.append(NSAttributedString(string: "\n\n", attributes: [.font: font, .paragraphStyle: paragraph]))
        }
        return (result, starts)
    }

    // Marks path-shaped tokens that resolve to real files as links. Tokens are
    // whitespace-separated runs with common trailing punctuation stripped; the
    // link payload carries the resolved path + line for the click handler.
    private func linkified(_ text: String, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: attributes)
        let nsText = text as NSString
        var searchStart = 0
        for token in text.split(whereSeparator: { $0.isWhitespace || $0 == "`" || $0 == "(" || $0 == ")" }) {
            var candidate = String(token)
            while let last = candidate.last, ",.;:'\"".contains(last) {
                candidate.removeLast()
            }
            // Cheap pre-filter before touching the filesystem: needs a path
            // separator or a tilde, like the things Claude actually prints.
            guard candidate.contains("/") || candidate.hasPrefix("~") else { continue }
            guard let target = resolveFileReference(candidate, relativeTo: sessionCwd) else { continue }
            let range = nsText.range(of: candidate, range: NSRange(location: searchStart, length: nsText.length - searchStart))
            guard range.location != NSNotFound else { continue }
            searchStart = NSMaxRange(range)
            result.addAttribute(.link, value: "\(target.line ?? 0)|\(target.path)", range: range)
        }
        return result
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let payload = link as? String,
              let separator = payload.firstIndex(of: "|") else { return false }
        let line = Int(payload[..<separator])
        let path = String(payload[payload.index(after: separator)...])
        pane?.openFileLink(path: path, line: line.flatMap { $0 > 0 ? $0 : nil })
        return true
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

    // ROADMAP Phase 18 — hand the current selection to AppDelegate as a Claude
    // goal. No provenance: a JSONL transcript line is not a source location.
    func setSelectionAsGoal() {
        let range = textView.selectedRange()
        guard range.length > 0 else { NSSound.beep(); return }
        let text = (textView.string as NSString).substring(with: range)
        (NSApp.delegate as? AppDelegate)?.setSelectionAsGoal(text)
    }
}
