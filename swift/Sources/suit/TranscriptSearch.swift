import Cocoa

// Cross-transcript search (ROADMAP Phase 20). Phase 7 shows one live session's
// transcript; this makes the whole conversation history queryable — the context
// you lose steering several worktrees at once ("what did Claude do about the
// auth bug yesterday"). The corpus is Claude Code's own JSONL transcript store
// under ~/.claude/projects (live and historical alike land there), searched
// with the same ripgrep engine the project search uses, then each matching raw
// JSON line is parsed back into a readable snippet with parseTranscriptLine and
// grouped by session.

// Where the transcript JSONL lives. Resolves ~ from $HOME (not
// NSHomeDirectory()) so a harness can sandbox the corpus, matching
// ClaudeIntegration's convention.
func claudeProjectsDirectory() -> String {
    let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    return home + "/.claude/projects"
}

// A session's identity for the results grouping: which file, and how to label
// it (name + cwd + date).
struct TranscriptSessionInfo {
    let sessionId: String
    let displayName: String
    let cwd: String?
    let date: Date
}

// One matching transcript line, ready to render and to jump to.
struct TranscriptSearchResult {
    let session: TranscriptSessionInfo
    let transcriptPath: String
    let lineNumber: Int
    let snippet: String
    let matchRanges: [NSRange]
}

// Reads a transcript file's head to recover its cwd and (if present) the
// session summary line, for labeling historical files that aren't live
// sessions. Reads only a prefix — transcripts can be large.
func transcriptFileMeta(path: String, maxBytes: Int = 128 * 1024) -> (cwd: String?, summary: String?) {
    guard let handle = FileHandle(forReadingAtPath: path) else { return (nil, nil) }
    defer { try? handle.close() }
    let data = (try? handle.read(upToCount: maxBytes)) ?? Data()
    guard let text = String(data: data, encoding: .utf8) else { return (nil, nil) }
    var cwd: String?
    var summary: String?
    for line in text.split(separator: "\n") {
        guard let lineData = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
        if summary == nil, object["type"] as? String == "summary",
           let value = (object["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            summary = value
        }
        if cwd == nil, let value = object["cwd"] as? String, !value.isEmpty {
            cwd = value
        }
        if cwd != nil, summary != nil { break }
    }
    return (cwd, summary)
}

// The searcher: streams ripgrep over the JSONL corpus, converts each matching
// raw line into a readable snippet, and groups by session. Reuses
// RipgrepSearcher for the streaming/cancel/generation machinery; the raw JSON
// line ripgrep returns is re-parsed here so results read as conversation, not
// as escaped JSON.
final class TranscriptSearcher {
    // Batched results, main queue. Called repeatedly as output streams in.
    var onResults: (([TranscriptSearchResult]) -> Void)?
    // Main queue, once per search (unless cancelled). errorMessage is set on a
    // real ripgrep failure.
    var onFinished: ((_ truncated: Bool, _ errorMessage: String?) -> Void)?

    private let rg = RipgrepSearcher()
    private var root = claudeProjectsDirectory()
    private var query = ""
    // Session-info cache, keyed by absolute transcript path, so a file matched
    // many times is only resolved once per search.
    private var infoCache: [String: TranscriptSessionInfo] = [:]

    init() {
        rg.onMatches = { [weak self] matches in
            self?.handle(matches)
        }
        rg.onFinished = { [weak self] truncated, error in
            self?.onFinished?(truncated, error)
        }
    }

    func cancel() {
        rg.cancel()
    }

    func search(query: String) {
        self.query = query
        infoCache = [:]
        root = claudeProjectsDirectory()

        guard !query.isEmpty else {
            rg.cancel()
            onFinished?(false, nil)
            return
        }
        guard FileManager.default.fileExists(atPath: root) else {
            onFinished?(false, "No Claude transcripts found (\(root))")
            return
        }
        rg.start(RipgrepOptions(
            pattern: query,
            isRegex: false,
            caseSensitive: false,
            globs: "*.jsonl",
            rootDirectory: root,
            searchHidden: true,
            respectIgnore: false
        ))
    }

    private func handle(_ matches: [SearchMatch]) {
        var results: [TranscriptSearchResult] = []
        for match in matches {
            // A line can hit inside JSON structure (keys, tool plumbing) rather
            // than conversation text; snippet(for:) drops those, keeping only
            // lines whose parsed content actually contains the query.
            guard let (snippet, ranges) = Self.snippet(forRawLine: match.lineText, query: query) else { continue }
            let absolute = root + "/" + match.relativePath
            let info = sessionInfo(forPath: absolute, relativePath: match.relativePath)
            results.append(TranscriptSearchResult(
                session: info,
                transcriptPath: absolute,
                lineNumber: match.lineNumber,
                snippet: snippet,
                matchRanges: ranges
            ))
        }
        if !results.isEmpty {
            onResults?(results)
        }
    }

    private func sessionInfo(forPath path: String, relativePath: String) -> TranscriptSessionInfo {
        if let cached = infoCache[path] { return cached }
        let sessionId = ((relativePath as NSString).lastPathComponent as NSString).deletingPathExtension

        let info: TranscriptSessionInfo
        if let live = ClaudeSessionMonitor.shared.sessions.first(where: { $0.transcriptPath == path }) {
            info = TranscriptSessionInfo(
                sessionId: sessionId, displayName: live.displayName, cwd: live.cwd, date: live.updatedAt
            )
        } else {
            let meta = transcriptFileMeta(path: path)
            let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
            let name = meta.summary
                ?? meta.cwd.map { ($0 as NSString).lastPathComponent }
                ?? String(sessionId.prefix(8))
            info = TranscriptSessionInfo(
                sessionId: sessionId, displayName: name, cwd: meta.cwd, date: modified ?? .distantPast
            )
        }
        infoCache[path] = info
        return info
    }

    // Parses a raw JSONL line and returns the first parsed entry whose text
    // contains the query, plus the query's ranges within that text — the
    // readable snippet for a match. nil when no parsed entry contains the query
    // (a structural-only ripgrep hit).
    static func snippet(forRawLine raw: String, query: String) -> (String, [NSRange])? {
        for entry in parseTranscriptLine(raw) {
            let text = entry.plainText.replacingOccurrences(of: "\n", with: " ")
            let ranges = plainMatchRanges(in: text, query: query)
            if !ranges.isEmpty {
                return windowedSnippet(text, ranges: ranges)
            }
        }
        return nil
    }

    // Case-insensitive occurrences of `query` in `text` as UTF-16 ranges.
    static func plainMatchRanges(in text: String, query: String) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let ns = text as NSString
        var ranges: [NSRange] = []
        var searchStart = 0
        while searchStart < ns.length {
            let found = ns.range(
                of: query, options: [.caseInsensitive],
                range: NSRange(location: searchStart, length: ns.length - searchStart)
            )
            guard found.location != NSNotFound else { break }
            ranges.append(found)
            searchStart = found.location + max(found.length, 1)
        }
        return ranges
    }

    // Keeps a snippet short while ensuring the first match stays visible:
    // slides the window so the match isn't pushed off the truncated end, with
    // ellipses marking either trimmed side and the ranges shifted to suit.
    static func windowedSnippet(_ text: String, ranges: [NSRange], limit: Int = 280) -> (String, [NSRange]) {
        let ns = text as NSString
        guard ns.length > limit, let first = ranges.first else {
            return (text, ranges)
        }
        // Start ~40 chars before the first match so there's leading context.
        let lead = 40
        var start = max(0, first.location - lead)
        let prefixEllipsis = start > 0
        // Snap to a word boundary near the cut so we don't slice mid-word.
        if prefixEllipsis {
            let scanRange = NSRange(location: start, length: min(20, ns.length - start))
            let space = ns.range(of: " ", range: scanRange)
            if space.location != NSNotFound { start = space.location + 1 }
        }
        let ellipsisPrefixLen = prefixEllipsis ? 1 : 0
        var length = min(limit - ellipsisPrefixLen, ns.length - start)
        let suffixEllipsis = start + length < ns.length
        if suffixEllipsis { length = max(0, length - 1) }

        var snippet = ns.substring(with: NSRange(location: start, length: length))
        // The kept window starts at `start`; a prepended "…" shifts every range
        // right by one, so the net shift of an original range is start - 1.
        let shift = start - ellipsisPrefixLen
        var shifted: [NSRange] = []
        for range in ranges {
            let loc = range.location - shift
            guard loc >= ellipsisPrefixLen, loc + range.length <= ellipsisPrefixLen + (snippet as NSString).length else { continue }
            shifted.append(NSRange(location: loc, length: range.length))
        }
        if prefixEllipsis { snippet = "…" + snippet }
        if suffixEllipsis { snippet += "…" }
        return (snippet, shifted)
    }
}

// MARK: - Outline nodes

// One session's worth of results. Equality follows sessionId so reloadData
// preserves expansion while batches stream in.
private final class TranscriptGroupNode: NSObject {
    let info: TranscriptSessionInfo
    let transcriptPath: String
    var results: [TranscriptResultNode] = []

    init(info: TranscriptSessionInfo, transcriptPath: String) {
        self.info = info
        self.transcriptPath = transcriptPath
    }

    override func isEqual(_ object: Any?) -> Bool {
        (object as? TranscriptGroupNode)?.info.sessionId == info.sessionId
    }
    override var hash: Int { info.sessionId.hashValue }
}

private final class TranscriptResultNode: NSObject {
    let result: TranscriptSearchResult
    init(result: TranscriptSearchResult) { self.result = result }
}

// MARK: - Row views

private final class TranscriptGroupRowView: NSTableCellView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let cwdLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        return f
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        addSubview(nameLabel)

        cwdLabel.font = .systemFont(ofSize: 10)
        cwdLabel.textColor = Theme.textFaint
        cwdLabel.lineBreakMode = .byTruncatingHead
        addSubview(cwdLabel)

        dateLabel.font = .systemFont(ofSize: 10)
        dateLabel.textColor = Theme.textFaint
        dateLabel.alignment = .right
        addSubview(dateLabel)

        countLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        countLabel.textColor = Theme.textDim
        countLabel.alignment = .center
        countLabel.wantsLayer = true
        countLabel.layer?.backgroundColor = Theme.hover.cgColor
        countLabel.layer?.cornerRadius = 3
        addSubview(countLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let dateWidth: CGFloat = 92
        let countWidth = countLabel.intrinsicContentSize.width + 10
        countLabel.frame = NSRect(x: bounds.width - countWidth - 4, y: (bounds.height - 14) / 2, width: countWidth, height: 14)
        dateLabel.frame = NSRect(x: bounds.width - countWidth - dateWidth - 10, y: (bounds.height - 14) / 2, width: dateWidth, height: 14)
        let nameWidth = min(nameLabel.intrinsicContentSize.width, max(0, bounds.width - countWidth - dateWidth - 24))
        nameLabel.frame = NSRect(x: 4, y: (bounds.height - 16) / 2, width: max(0, nameWidth), height: 16)
        let cwdX = nameLabel.frame.maxX + 6
        cwdLabel.frame = NSRect(x: cwdX, y: (bounds.height - 14) / 2, width: max(0, bounds.width - cwdX - countWidth - dateWidth - 16), height: 14)
    }

    func configure(with group: TranscriptGroupNode) {
        nameLabel.stringValue = group.info.displayName
        cwdLabel.stringValue = group.info.cwd.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? ""
        dateLabel.stringValue = group.info.date == .distantPast ? "" : Self.dateFormatter.string(from: group.info.date)
        countLabel.stringValue = " \(group.results.count) "
        needsLayout = true
    }
}

private final class TranscriptResultRowView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 4, y: (bounds.height - 16) / 2, width: max(0, bounds.width - 8), height: 16)
    }

    func configure(with node: TranscriptResultNode) {
        let result = node.result
        let text = NSMutableAttributedString(
            string: result.snippet,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: Theme.textDim,
            ]
        )
        let length = (result.snippet as NSString).length
        for range in result.matchRanges where range.location + range.length <= length {
            text.addAttributes([
                .font: NSFont.systemFont(ofSize: 11, weight: .bold),
                .foregroundColor: Theme.textPrimary,
                .backgroundColor: Theme.accent.withAlphaComponent(0.25),
            ], range: range)
        }
        label.attributedStringValue = text
        needsLayout = true
    }
}

// MARK: - Panel controller

private final class TranscriptSearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// The "Search Transcripts…" surface: a floating panel (same overlay chrome as
// the command palette) with a query field over a results outline grouped by
// session. Clicking a match opens that session's transcript pane anchored to
// the matching line.
final class TranscriptSearchController: NSObject, NSWindowDelegate, NSTextFieldDelegate,
    NSOutlineViewDataSource, NSOutlineViewDelegate {

    // Set by AppDelegate; opens the picked result (path + cwd + title + line).
    var onOpen: ((TranscriptSearchResult) -> Void)?

    private let panel: TranscriptSearchPanel
    private let searchField = NSTextField(frame: .zero)
    private let statusLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView(frame: .zero)
    private let outlineView = NSOutlineView(frame: .zero)

    private let searcher = TranscriptSearcher()
    private var debounce: DispatchWorkItem?

    private var groups: [TranscriptGroupNode] = []
    private var groupsById: [String: TranscriptGroupNode] = [:]
    private var resultCount = 0
    private var isSearching = false

    private static let panelSize = NSSize(width: 640, height: 460)
    private static let fieldHeight: CGFloat = 46
    private static let statusHeight: CGFloat = 20

    override init() {
        panel = TranscriptSearchPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false

        super.init()
        panel.delegate = self

        let effect = NSView(frame: NSRect(origin: .zero, size: Self.panelSize))
        effect.wantsLayer = true
        effect.layer?.backgroundColor = Theme.overlay.cgColor
        effect.layer?.cornerRadius = Theme.Metrics.overlayRadius
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = Theme.hairline.cgColor
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]
        panel.contentView = effect

        searchField.frame = NSRect(
            x: 16, y: Self.panelSize.height - Self.fieldHeight + 8,
            width: Self.panelSize.width - 32, height: 30
        )
        searchField.font = .systemFont(ofSize: 18, weight: .light)
        searchField.placeholderString = "Search all Claude transcripts…"
        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.delegate = self
        effect.addSubview(searchField)

        let separator = NSBox(frame: NSRect(x: 0, y: Self.panelSize.height - Self.fieldHeight, width: Self.panelSize.width, height: 1))
        separator.boxType = .separator
        effect.addSubview(separator)

        statusLabel.frame = NSRect(x: 16, y: Self.panelSize.height - Self.fieldHeight - Self.statusHeight, width: Self.panelSize.width - 32, height: 16)
        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = Theme.textFaint
        statusLabel.lineBreakMode = .byTruncatingTail
        effect.addSubview(statusLabel)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowHeight = 22
        outlineView.indentationPerLevel = 10
        outlineView.autoresizesOutlineColumn = false
        outlineView.backgroundColor = .clear
        outlineView.style = .sourceList
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(rowClicked)

        let listTop = Self.panelSize.height - Self.fieldHeight - Self.statusHeight - 1
        scrollView.frame = NSRect(x: 0, y: 0, width: Self.panelSize.width, height: listTop)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        effect.addSubview(scrollView)

        searcher.onResults = { [weak self] results in self?.append(results) }
        searcher.onFinished = { [weak self] truncated, error in self?.finished(truncated: truncated, error: error) }
    }

    var isVisible: Bool { panel.isVisible }

    // MARK: Showing / hiding

    func show(relativeTo window: NSWindow?) {
        searchField.stringValue = ""
        clearResults()
        statusLabel.stringValue = "Type to search prompts, replies, and tool calls across every session."

        if let window {
            let frame = window.frame
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - Self.panelSize.width / 2,
                y: frame.maxY - Self.panelSize.height - frame.height * 0.14
            ))
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
    }

    private func close() {
        searcher.cancel()
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    // MARK: Searching

    func controlTextDidChange(_ obj: Notification) {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runSearch() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func runSearch() {
        searcher.cancel()
        clearResults()
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            statusLabel.stringValue = ""
            return
        }
        isSearching = true
        statusLabel.stringValue = "Searching transcripts…"
        searcher.search(query: query)
    }

    private func clearResults() {
        groups = []
        groupsById = [:]
        resultCount = 0
        isSearching = false
        outlineView.reloadData()
    }

    private func append(_ results: [TranscriptSearchResult]) {
        guard isSearching else { return }
        var newGroups: [TranscriptGroupNode] = []
        for result in results {
            let id = result.session.sessionId
            let group: TranscriptGroupNode
            if let existing = groupsById[id] {
                group = existing
            } else {
                group = TranscriptGroupNode(info: result.session, transcriptPath: result.transcriptPath)
                groupsById[id] = group
                groups.append(group)
                newGroups.append(group)
            }
            group.results.append(TranscriptResultNode(result: result))
        }
        resultCount += results.count
        // Most recent sessions first — that's the "yesterday" recall the phase
        // is for. Stable re-sort keeps groups meaningful as batches stream in.
        groups.sort { $0.info.date > $1.info.date }
        outlineView.reloadData()
        for group in newGroups {
            outlineView.expandItem(group)
        }
        updateStatus(suffix: isSearching ? "…" : "")
    }

    private func finished(truncated: Bool, error: String?) {
        isSearching = false
        if let error {
            statusLabel.stringValue = error
            return
        }
        updateStatus(suffix: truncated ? " (first \(RipgrepSearcher.maxMatches))" : "")
    }

    private func updateStatus(suffix: String) {
        if resultCount == 0 {
            statusLabel.stringValue = isSearching ? "Searching transcripts…" : "No matching transcript entries"
            return
        }
        let sessions = groups.count == 1 ? "1 session" : "\(groups.count) sessions"
        statusLabel.stringValue = "\(resultCount) matches in \(sessions)\(suffix)"
    }

    // MARK: Opening

    @objc private func rowClicked() {
        let row = outlineView.clickedRow
        guard row >= 0 else { return }
        let item = outlineView.item(atRow: row)
        if let group = item as? TranscriptGroupNode {
            if outlineView.isItemExpanded(group) {
                outlineView.collapseItem(group)
            } else {
                outlineView.expandItem(group)
            }
        } else if let node = item as? TranscriptResultNode {
            close()
            let result = node.result
            DispatchQueue.main.async { [weak self] in
                self?.onOpen?(result)
            }
        }
    }

    // MARK: Keyboard driving

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            openSelected()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }

    private func moveSelection(by delta: Int) {
        let count = outlineView.numberOfRows
        guard count > 0 else { return }
        let current = outlineView.selectedRow
        let next = min(max(current + delta, 0), count - 1)
        outlineView.selectRowIndexes([next], byExtendingSelection: false)
        outlineView.scrollRowToVisible(next)
    }

    private func openSelected() {
        let row = outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? TranscriptResultNode else { return }
        close()
        let result = node.result
        DispatchQueue.main.async { [weak self] in
            self?.onOpen?(result)
        }
    }

    // MARK: NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let group = item as? TranscriptGroupNode else { return groups.count }
        return group.results.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let group = item as? TranscriptGroupNode else { return groups[index] }
        return group.results[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is TranscriptGroupNode
    }

    // MARK: NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let group = item as? TranscriptGroupNode {
            let identifier = NSUserInterfaceItemIdentifier("transcriptGroupRow")
            let view = outlineView.makeView(withIdentifier: identifier, owner: self) as? TranscriptGroupRowView ?? {
                let created = TranscriptGroupRowView(frame: .zero)
                created.identifier = identifier
                return created
            }()
            view.configure(with: group)
            return view
        }
        if let node = item as? TranscriptResultNode {
            let identifier = NSUserInterfaceItemIdentifier("transcriptResultRow")
            let view = outlineView.makeView(withIdentifier: identifier, owner: self) as? TranscriptResultRowView ?? {
                let created = TranscriptResultRowView(frame: .zero)
                created.identifier = identifier
                return created
            }()
            view.configure(with: node)
            return view
        }
        return nil
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        ThemedTableRowView()
    }
}
