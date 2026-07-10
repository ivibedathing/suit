import Cocoa

// Claude transcript pane: renders a session's JSONL
// transcript — the conversation itself, not the terminal's scrollback — and
// live-tails it while Claude works. Read-only, like the file viewer: what
// Claude *did* (prompts, replies, tool calls) at a glance, with file paths
// clickable into the viewer pane.
//
// Transcript-line parsing (TranscriptEntry, parseTranscriptLine,
// resolveFileReference) lives in TranscriptParsing.swift; the live-tail /
// file-watching lives in TranscriptPane+Tail.swift.

// MARK: - Text view

// Mirrors ViewerTextView: content backpointer for pane-scoped actions; focus
// visuals are derived by the window controller, not reported from here.
final class TranscriptTextView: NSTextView {
    weak var transcriptContent: TranscriptPaneContent?

    // Send the selection into a Claude session as a `/goal`.
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

    var entries: [TranscriptEntry] = []
    // The 1-based source-file line each entry was parsed from, parallel to
    // `entries` — lets cross-transcript search jump the pane to a matching line
    // `lineCounter` counts every complete line read, entry-producing
    // or not, so it tracks the file's real line numbers (what ripgrep reports).
    var entrySourceLines: [Int] = []
    var lineCounter = 0
    // Char offset (into the rendered text) of each entry, parallel to `entries`;
    // recomputed by a full render(), consumed by jump(toSourceLine:).
    private var entryCharStarts: [Int] = []
    // Which entry the last jump anchored on (nil if none) — the anchor visible
    // to the harness/verification.
    private(set) var anchoredEntryIndex: Int?
    // Live-tail state: how far into the file we've parsed, plus any trailing
    // partial line the last read stopped in the middle of.
    var readOffset: UInt64 = 0
    var remainder = Data()
    var watchSource: DispatchSourceFileSystemObject?

    private var font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
    private var baseTextColor: NSColor = .textColor

    // A runaway transcript stops being a conversation view and starts being a
    // memory problem; keep the most recent slice.
    static let maxEntries = 4000

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
    // sessions this way).
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

    // MARK: Rendering

    func render() {
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
    // clicked result. Rebuilds the full document first so the
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

    func append(attributed: NSAttributedString) {
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

    func attributedString(for entries: [TranscriptEntry]) -> NSAttributedString {
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

    // Hand the current selection to AppDelegate as a Claude
    // goal. No provenance: a JSONL transcript line is not a source location.
    func setSelectionAsGoal() {
        let range = textView.selectedRange()
        guard range.length > 0 else { NSSound.beep(); return }
        let text = (textView.string as NSString).substring(with: range)
        (NSApp.delegate as? AppDelegate)?.setSelectionAsGoal(text)
    }
}
