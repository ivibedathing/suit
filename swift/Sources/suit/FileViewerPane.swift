import Cocoa

// A read-only text view that knows which content owns it, mirroring
// PaneTerminalView's pattern, so menu actions (Go to Line) reach the viewer
// via the responder chain. Focus visuals are the window controller's job.
final class ViewerTextView: NSTextView {
    weak var viewerContent: FileViewerPaneContent?

    @objc func goToLine(_ sender: Any?) {
        viewerContent?.promptForLine()
    }

    @objc func toggleBlame(_ sender: Any?) {
        viewerContent?.toggleBlame()
    }

    @objc func showFileHistory(_ sender: Any?) {
        viewerContent?.showFileHistory()
    }

    // ROADMAP Phase 18 — send the selection into a Claude session as a `/goal`.
    @objc func setAsGoal(_ sender: Any?) {
        viewerContent?.setSelectionAsGoal()
    }

    @objc func toggleBookmark(_ sender: Any?) {
        viewerContent?.toggleBookmarkAtCurrentLine()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let copyItem = menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        copyItem.isEnabled = selectedRange().length > 0
        menu.addItem(withTitle: "Go to Line…", action: #selector(goToLine(_:)), keyEquivalent: "")
        let goalItem = menu.addItem(withTitle: "Set as Goal", action: #selector(setAsGoal(_:)), keyEquivalent: "")
        goalItem.isEnabled = selectedRange().length > 0
        menu.addItem(withTitle: "Toggle Bookmark", action: #selector(toggleBookmark(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        let blameItem = menu.addItem(withTitle: "Toggle Blame", action: #selector(toggleBlame(_:)), keyEquivalent: "")
        blameItem.state = (viewerContent?.blameVisible ?? false) ? .on : .off
        menu.addItem(withTitle: "Show File History", action: #selector(showFileHistory(_:)), keyEquivalent: "")
        return menu
    }
}

// The line-number gutter: draws the number of each visible line fragment's
// first fragment, in the same font family as the document at a smaller size.
final class LineNumberRulerView: NSRulerView, NSViewToolTipOwner {
    weak var textView: NSTextView?
    var textColor: NSColor = Theme.textFaint
    var gutterBackground: NSColor = .clear

    // Character offsets of each line start, maintained by the viewer on load —
    // cheaper than re-walking the string on every draw.
    var lineStarts: [Int] = [0]

    // Lines changed vs HEAD (ROADMAP Phase 5), drawn as an orange bar along
    // the gutter's right edge.
    var changedLines = IndexSet() {
        didSet { needsDisplay = true }
    }

    // Blame gutter (ROADMAP Phase 17): a toggleable column left of the line
    // numbers showing each line's last-touching commit (sha + author, tinted by
    // age), the full subject on hover, and the sha clickable to that commit's
    // diff. Reuses the ruler's line-fragment walk — the same plumbing as the
    // changed-line marks above.
    var blameVisible = false {
        didSet {
            guard blameVisible != oldValue else { return }
            updateThickness()
            needsDisplay = true
        }
    }
    var blameByLine: [Int: BlameLine] = [:] {
        didSet { if blameVisible { needsDisplay = true } }
    }
    // A commit's short sha (from a clicked blame line) → open its diff.
    var onBlameClick: ((BlameLine) -> Void)?

    private static let blameWidth: CGFloat = 172

    // Bookmarked lines in this file (ROADMAP Phase 22), drawn as an accent bar
    // along the gutter's *left* edge (the right edge is the changed-line bar).
    var bookmarkedLines = IndexSet() {
        didSet { needsDisplay = true }
    }

    // A gutter click toggles the bookmark on the clicked line.
    var onToggleLine: ((Int) -> Void)?

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        updateThickness()
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var blameColumnWidth: CGFloat { blameVisible ? Self.blameWidth : 0 }

    func updateThickness() {
        let digits = max(3, String(lineStarts.count).count)
        let charWidth = ("0" as NSString).size(withAttributes: [.font: numberFont]).width
        ruleThickness = blameColumnWidth + CGFloat(digits) * charWidth + 12
    }

    private var numberFont: NSFont {
        let base = textView?.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        return NSFont.monospacedDigitSystemFont(ofSize: max(8, base.pointSize - 2), weight: .regular)
    }

    private var blameFont: NSFont {
        let base = textView?.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        return NSFont.monospacedSystemFont(ofSize: max(8, base.pointSize - 3), weight: .regular)
    }

    // The document line under a window-space point, mapped through the text
    // view so it stays correct regardless of the ruler's own flippedness.
    private func line(atWindowPoint windowPoint: NSPoint) -> Int? {
        guard let textView, let layoutManager = textView.layoutManager,
              let container = textView.textContainer, lineStarts.count > 1 else { return nil }
        let pointInText = textView.convert(windowPoint, from: nil)
        let glyph = layoutManager.glyphIndex(for: NSPoint(x: 2, y: pointInText.y), in: container)
        let charIndex = layoutManager.characterIndexForGlyph(at: glyph)
        return lineNumber(forCharacterAt: charIndex)
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        // A click in the blame column on a committed line opens that commit's
        // diff (ROADMAP Phase 17).
        if blameVisible, location.x <= blameColumnWidth,
           let line = line(atWindowPoint: event.locationInWindow),
           let blame = blameByLine[line], !blame.isUncommitted {
            onBlameClick?(blame)
            return
        }
        // Otherwise a gutter click toggles the bookmark on that line
        // (ROADMAP Phase 22).
        if let line = line(atWindowPoint: event.locationInWindow) {
            onToggleLine?(line)
            return
        }
        super.mouseDown(with: event)
    }

    // The blame column carries the commit subject as a tooltip (registered over
    // the whole column each draw so it tracks resize/scroll).
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        let windowPoint = convert(point, to: nil)
        guard let line = line(atWindowPoint: windowPoint), let blame = blameByLine[line] else { return "" }
        if blame.isUncommitted { return "Uncommitted changes" }
        return "\(blame.shortSha)  \(blame.author)\n\(blame.summary)"
    }

    // The line number owning a character offset: the index of the last line
    // start ≤ offset (binary search — files can be hundreds of thousands of lines).
    private func lineNumber(forCharacterAt offset: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low + 1
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        gutterBackground.setFill()
        bounds.fill()

        // Re-register the blame column's tooltip each draw so it tracks
        // resize/scroll; clearing on every draw also wipes residue once blame
        // is toggled back off.
        removeAllToolTips()
        if blameVisible {
            addToolTip(NSRect(x: 0, y: 0, width: blameColumnWidth, height: bounds.height), owner: self, userData: nil)
            Theme.hairline.setFill()
            NSRect(x: blameColumnWidth - 0.5, y: 0, width: 0.5, height: bounds.height).fill()
        }

        guard let textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        let visibleRect = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
        let attributes: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: textColor]
        let now = Date().timeIntervalSince1970
        let blameFont = self.blameFont

        var lastLine = -1
        var glyphIndex = glyphRange.location
        while glyphIndex < NSMaxRange(glyphRange) {
            var fragmentGlyphRange = NSRange()
            let fragmentRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &fragmentGlyphRange)
            let charIndex = layoutManager.characterIndexForGlyph(at: fragmentGlyphRange.location)
            let line = lineNumber(forCharacterAt: charIndex)
            // Wrapped continuations share the line number of their first fragment;
            // only the first gets a label.
            if line != lastLine {
                lastLine = line
                let label = "\(line)" as NSString
                let size = label.size(withAttributes: attributes)
                let y = fragmentRect.minY - visibleRect.minY + textView.textContainerInset.height + (fragmentRect.height - size.height) / 2
                label.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: y), withAttributes: attributes)

                if blameVisible, let blame = blameByLine[line] {
                    let tint = GitAgeTint.color(forTime: blame.time, now: now)
                    let text = blame.isUncommitted
                        ? NSAttributedString(string: "Uncommitted", attributes: [.font: blameFont, .foregroundColor: tint])
                        : NSAttributedString(string: "\(blame.shortSha)  \(blame.author)", attributes: [.font: blameFont, .foregroundColor: tint])
                    let blameY = fragmentRect.minY - visibleRect.minY + textView.textContainerInset.height + (fragmentRect.height - text.size().height) / 2
                    NSGraphicsContext.current?.saveGraphicsState()
                    NSRect(x: 6, y: blameY, width: blameColumnWidth - 12, height: fragmentRect.height).clip()
                    text.draw(at: NSPoint(x: 6, y: blameY))
                    NSGraphicsContext.current?.restoreGraphicsState()
                }
            }
            if changedLines.contains(line) {
                Theme.sessionBusy.withAlphaComponent(0.75).setFill()
                let barY = fragmentRect.minY - visibleRect.minY + textView.textContainerInset.height
                NSRect(x: ruleThickness - 2.5, y: barY, width: 2.5, height: fragmentRect.height).fill()
            }
            if bookmarkedLines.contains(line) {
                Theme.accent.setFill()
                let barY = fragmentRect.minY - visibleRect.minY + textView.textContainerInset.height
                NSRect(x: 0, y: barY, width: 3, height: fragmentRect.height).fill()
            }
            glyphIndex = NSMaxRange(fragmentGlyphRange)
        }

        // Empty document / trailing empty line still shows "1" so the gutter
        // never looks broken on an empty file.
        if lastLine == -1 && lineStarts.count == 1 {
            let label = "1" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: textView.textContainerInset.height), withAttributes: attributes)
        }
    }

}

// The viewer's root view: text scroll view on the left, minimap strip on the
// right. Manual layout like the rest of the pane tree.
final class ViewerContainerView: NSView {
    let scrollView: NSScrollView
    let minimap: MinimapView

    init(scrollView: NSScrollView, minimap: MinimapView) {
        self.scrollView = scrollView
        self.minimap = minimap
        super.init(frame: .zero)
        addSubview(scrollView)
        addSubview(minimap)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let minimapWidth = minimap.isHidden ? 0 : MinimapView.preferredWidth
        scrollView.frame = NSRect(x: 0, y: 0, width: max(0, bounds.width - minimapWidth), height: bounds.height)
        minimap.frame = NSRect(x: bounds.width - minimapWidth, y: 0, width: minimapWidth, height: bounds.height)
    }
}

// Read-only file viewing inside the pane tree (ROADMAP Phase 1): line numbers,
// go-to-line, jump-to-line from the fuzzy opener / terminal links, syntax
// highlighting and a minimap (Phase 3). Deliberately not an editor — selection
// and copy only.
final class FileViewerPaneContent: NSObject, FileBackedPaneContent {
    weak var pane: Pane?
    weak var tab: Tab?

    private let scrollView = NSScrollView(frame: .zero)
    private let textView: ViewerTextView
    private let ruler: LineNumberRulerView
    private let minimap = MinimapView(frame: .zero)
    private var container: ViewerContainerView!

    private(set) var filePath: String?
    private var lineStarts: [Int] = [0]
    private var syntaxSpans: [SyntaxSpan] = []
    private var baseTextColor: NSColor = .textColor

    // Files past this stop being useful to scroll through and start being a
    // memory problem; the viewer refuses rather than beachballing.
    private static let maxFileSize = 8 * 1024 * 1024

    var view: NSView { container }
    var focusTarget: NSView { textView }
    var defaultTitle: String { "Viewer" }

    var workingDirectory: String? {
        guard let filePath else { return nil }
        return (filePath as NSString).deletingLastPathComponent
    }

    override init() {
        textView = ViewerTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.drawsBackground = true

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        ruler = LineNumberRulerView(scrollView: scrollView, textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        super.init()
        textView.viewerContent = self
        container = ViewerContainerView(scrollView: scrollView, minimap: minimap)

        // Gutter click toggles the bookmark on that line (ROADMAP Phase 22).
        ruler.onToggleLine = { [weak self] line in
            self?.toggleBookmark(atLine: line)
        }

        minimap.onJump = { [weak self] fraction in
            self?.scroll(toFraction: fraction)
        }

        // Chaining (ROADMAP Phase 17): clicking a blame line's sha opens that
        // commit's per-file diff.
        ruler.onBlameClick = { [weak self] blame in
            self?.openCommitDiff(sha: blame.sha)
        }

        // The gutter and minimap viewport track scrolling and text relayout.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )
        // Changed-region marks refresh when any repo's status changes (the
        // handler filters to this file's repo).
        NotificationCenter.default.addObserver(
            self, selector: #selector(gitStatusChanged),
            name: GitStatusMonitor.didUpdate, object: nil
        )
        // Bookmarks changing anywhere (another window, the sidebar list)
        // refresh this file's gutter/minimap ticks.
        NotificationCenter.default.addObserver(
            self, selector: #selector(bookmarksChanged),
            name: BookmarksStore.didUpdate, object: nil
        )
    }

    // MARK: - Changed regions (ROADMAP Phase 5)

    private var changedLines = IndexSet()
    private var jumpMarkerLine: Int?

    @objc private func gitStatusChanged(_ note: Notification) {
        refreshChangedLines()
    }

    private func refreshChangedLines() {
        guard let filePath else { return }
        let generation = loadGeneration
        GitChangedLines.compute(filePath: filePath) { [weak self] lines in
            guard let self, self.loadGeneration == generation else { return }
            self.changedLines = lines
            self.ruler.changedLines = lines
            self.updateMinimapMarkers()
        }
    }

    // The minimap shows git-changed regions in orange plus the last jump
    // target in the accent color. Capped so a full-file rewrite doesn't drown
    // the strip in ticks.
    private func updateMinimapMarkers() {
        var markers: [MinimapView.Marker] = changedLines.prefix(2_000).map {
            MinimapView.Marker(line: $0, color: Theme.sessionBusy)
        }
        for line in bookmarkedLines {
            markers.append(MinimapView.Marker(line: line, color: Theme.accent))
        }
        if let jumpMarkerLine {
            markers.append(MinimapView.Marker(line: jumpMarkerLine, color: Theme.accent))
        }
        minimap.setMarkers(markers)
    }

    // MARK: - Blame gutter + file history (ROADMAP Phase 17)

    private(set) var blameVisible = false

    // View ▸ Toggle Blame / ⌃⌘B / palette. Flips the gutter column; the first
    // reveal loads blame for the current file.
    func toggleBlame() {
        blameVisible.toggle()
        ruler.blameVisible = blameVisible
        applyWrapWidth()
        if blameVisible {
            loadBlame()
        }
    }

    private func loadBlame() {
        guard let filePath else { return }
        let generation = loadGeneration
        GitBlame.compute(filePath: filePath) { [weak self] lines in
            guard let self, self.loadGeneration == generation else { return }
            self.ruler.blameByLine = lines
        }
    }

    // View ▸ Show File History / palette: reveal the Git tab's File History
    // section for this file. Routed through the pane host (the window controller
    // owns the sidebar).
    func showFileHistory() {
        guard let filePath else { return }
        pane?.showFileHistory(forPath: filePath)
    }

    private func openCommitDiff(sha: String) {
        guard let filePath else { return }
        pane?.openCommitDiff(forFile: filePath, sha: sha)
    }

    // MARK: - Bookmarks (ROADMAP Phase 22)

    private var bookmarkedLines = IndexSet()

    @objc private func bookmarksChanged(_ note: Notification) {
        refreshBookmarks()
    }

    // Pulls this file's bookmarked lines out of the store into the gutter and
    // minimap.
    private func refreshBookmarks() {
        guard let filePath else {
            bookmarkedLines = IndexSet()
            ruler.bookmarkedLines = IndexSet()
            updateMinimapMarkers()
            return
        }
        bookmarkedLines = IndexSet(BookmarksStore.shared.lines(inFile: filePath))
        ruler.bookmarkedLines = bookmarkedLines
        updateMinimapMarkers()
    }

    // The 1-based line the caret (selection start) sits on.
    private var currentLine: Int {
        let caret = textView.selectedRange().location
        var line = 1
        for (i, start) in lineStarts.enumerated() where start <= caret {
            line = i + 1
        }
        return line
    }

    // The text of a 1-based line, trimmed of its newline — the bookmark snippet.
    private func text(ofLine line: Int) -> String {
        guard lineStarts.indices.contains(line - 1) else { return "" }
        let start = lineStarts[line - 1]
        let end = line < lineStarts.count ? lineStarts[line] : (textView.string as NSString).length
        let range = NSRange(location: start, length: max(0, end - start))
        return (textView.string as NSString).substring(with: range)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Add/remove the bookmark at `line` (gutter click, and the toggle command
    // via currentLine). The store posts didUpdate, which refreshes every open
    // viewer of the file — including this one.
    func toggleBookmark(atLine line: Int) {
        guard let filePath else { NSSound.beep(); return }
        BookmarksStore.shared.toggle(path: filePath, line: line, snippet: text(ofLine: line), from: self)
    }

    // ⇧⌘L / the palette / the context menu: bookmark the caret's line.
    func toggleBookmarkAtCurrentLine() {
        toggleBookmark(atLine: currentLine)
    }

    @objc private func scrolled(_ note: Notification) {
        ruler.needsDisplay = true
        updateMinimapViewport()
    }

    // MARK: - Minimap

    private func updateMinimapViewport() {
        guard let documentView = scrollView.documentView else { return }
        let docHeight = documentView.frame.height
        guard docHeight > 0 else { return }
        let visible = scrollView.contentView.bounds
        minimap.setViewport(
            start: visible.minY / docHeight,
            end: visible.maxY / docHeight
        )
    }

    private func scroll(toFraction fraction: CGFloat) {
        guard let documentView = scrollView.documentView else { return }
        let docHeight = documentView.frame.height
        let visibleHeight = scrollView.contentView.bounds.height
        let target = max(0, min(docHeight - visibleHeight, fraction * docHeight - visibleHeight / 2))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: target))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // Applies syntax colors to the document and rebuilds the minimap. Runs the
    // scan off the main thread for anything nontrivial; the plain text is
    // already on screen, color arrives a beat later.
    private func rehighlight() {
        let text = textView.string
        guard let filePath, let language = CodeLanguage.detect(path: filePath),
              (text as NSString).length <= SyntaxHighlighter.maxLength else {
            syntaxSpans = []
            applySyntaxAttributes()
            rebuildMinimap()
            return
        }
        let generation = loadGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let spans = SyntaxHighlighter.highlight(text: text, language: language)
            DispatchQueue.main.async {
                guard let self, self.loadGeneration == generation else { return }
                self.syntaxSpans = spans
                self.applySyntaxAttributes()
                self.rebuildMinimap()
            }
        }
    }

    private func applySyntaxAttributes() {
        guard let storage = textView.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.removeAttribute(.foregroundColor, range: full)
        storage.addAttribute(.foregroundColor, value: baseTextColor, range: full)
        for span in syntaxSpans where NSMaxRange(span.range) <= storage.length {
            storage.addAttribute(.foregroundColor, value: span.kind.color, range: span.range)
        }
        storage.endEditing()
    }

    private func rebuildMinimap() {
        minimap.rebuild(
            text: textView.string,
            lineStarts: lineStarts,
            spans: syntaxSpans,
            baseColor: baseTextColor
        )
        updateMinimapViewport()
    }

    // MARK: - Loading

    // Bumped per load; async highlight results from a superseded load drop out.
    private var loadGeneration = 0

    func load(path: String, line: Int? = nil) {
        let standardized = (path as NSString).standardizingPath
        filePath = standardized
        loadGeneration += 1

        let text: String
        if let data = FileManager.default.contents(atPath: standardized) {
            if data.count > Self.maxFileSize {
                text = "\(standardized)\n\nFile is too large for the viewer (\(data.count / (1024 * 1024)) MB)."
            } else if data.prefix(8192).contains(0) {
                text = "\(standardized)\n\nBinary file (\(data.count) bytes)."
            } else {
                text = String(decoding: data, as: UTF8.self)
            }
        } else {
            text = "\(standardized)\n\nCould not read file."
        }

        textView.string = text
        recomputeLineStarts(for: text)
        ruler.lineStarts = lineStarts
        ruler.updateThickness()
        ruler.needsDisplay = true
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scroll(.zero)

        syntaxSpans = []
        changedLines = IndexSet()
        jumpMarkerLine = nil
        ruler.changedLines = IndexSet()
        ruler.blameByLine = [:]
        minimap.setMarkers([])
        rehighlight()
        refreshChangedLines()
        if blameVisible {
            loadBlame()
        }
        refreshBookmarks()

        tab?.contentTitleDidChange((standardized as NSString).lastPathComponent)

        if let line {
            jump(toLine: line)
        }
    }

    private func recomputeLineStarts(for text: String) {
        var starts = [0]
        let ns = text as NSString
        var index = 0
        while index < ns.length {
            let range = ns.range(of: "\n", options: [], range: NSRange(location: index, length: ns.length - index))
            if range.location == NSNotFound { break }
            starts.append(range.location + 1)
            index = range.location + 1
        }
        lineStarts = starts
    }

    // MARK: - Jumping

    func jump(toLine line: Int) {
        guard !lineStarts.isEmpty else { return }
        let clamped = min(max(line, 1), lineStarts.count)
        let start = lineStarts[clamped - 1]
        let end = clamped < lineStarts.count ? lineStarts[clamped] : (textView.string as NSString).length
        let range = NSRange(location: start, length: max(0, end - start))

        textView.setSelectedRange(NSRange(location: start, length: 0))
        textView.scrollRangeToVisible(range)

        // The jump target is marked on the minimap so "where did that link
        // take me" stays answerable after scrolling away.
        jumpMarkerLine = clamped
        updateMinimapMarkers()

        // A brief highlight so the eye lands on the right line, then fades out
        // of the way (temporary attributes never touch the document).
        guard let layoutManager = textView.layoutManager else { return }
        layoutManager.addTemporaryAttribute(
            .backgroundColor,
            value: Theme.accent.withAlphaComponent(0.3),
            forCharacterRange: range
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak layoutManager] in
            layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
        }
    }

    // MARK: - Scroll persistence (state restoration)

    // The 1-based line at the top of the visible rect — captured at quit so
    // the next launch can put the viewer back where it was.
    var firstVisibleLine: Int {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              lineStarts.count > 1 else { return 1 }
        let top = NSPoint(x: 0, y: max(0, scrollView.contentView.bounds.minY - textView.textContainerInset.height) + 1)
        let glyph = layoutManager.glyphIndex(for: top, in: textContainer)
        let charIndex = layoutManager.characterIndexForGlyph(at: glyph)
        for (i, start) in lineStarts.enumerated() where start > charIndex {
            return max(1, i)
        }
        return lineStarts.count
    }

    // jump(toLine:) with the attention-grabbing parts (selection move,
    // highlight, minimap marker) left out — restoring scroll shouldn't look
    // like a navigation event.
    func scrollTo(firstVisibleLine line: Int) {
        guard lineStarts.indices.contains(line - 1),
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let glyph = layoutManager.glyphIndexForCharacter(at: lineStarts[line - 1])
        let rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, rect.minY + textView.textContainerInset.height)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func promptForLine() {
        let alert = NSAlert()
        alert.messageText = "Go to Line"
        alert.informativeText = "1 – \(lineStarts.count)"
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn, let line = Int(field.stringValue) else { return }
        jump(toLine: line)
    }

    // ROADMAP Phase 18 — hand the current selection to AppDelegate as a Claude
    // goal, tagged with this file and the selection's line span so provenance
    // (when enabled) reads `From <file>:<start>-<end>:`.
    func setSelectionAsGoal() {
        let range = textView.selectedRange()
        guard range.length > 0 else { NSSound.beep(); return }
        let text = (textView.string as NSString).substring(with: range)
        let start = lineNumber(forCharacterAt: range.location)
        let end = lineNumber(forCharacterAt: range.location + range.length - 1)
        (NSApp.delegate as? AppDelegate)?.setSelectionAsGoal(text, file: filePath, startLine: start, endLine: end)
    }

    // The 1-based line owning a character offset (last line start ≤ offset),
    // by binary search over lineStarts — mirrors the gutter's own lookup.
    private func lineNumber(forCharacterAt offset: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low + 1
    }

    // MARK: - Word wrap (View ▸ Word Wrap, global setting owned by AppDelegate)

    private var wordWrap = true

    func setWordWrap(_ wrap: Bool) {
        guard wrap != wordWrap else { return }
        wordWrap = wrap
        scrollView.hasHorizontalScroller = !wrap
        textView.isHorizontallyResizable = !wrap
        if wrap {
            textView.autoresizingMask = [.width]
            textView.textContainer?.widthTracksTextView = true
            applyWrapWidth()
        } else {
            textView.autoresizingMask = []
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude
            )
        }
        ruler.needsDisplay = true
    }

    // Sizes the wrap width to the clip area minus the gutter — used when word
    // wrap turns on and whenever the gutter's thickness changes (blame toggle),
    // so wrapped text reflows to the space the gutter leaves.
    private func applyWrapWidth() {
        guard wordWrap else {
            ruler.needsDisplay = true
            return
        }
        // Re-tile first: hiding the horizontal scroller / a thickness change
        // resizes the clip view, and the wrap width must match the new size. The
        // gutter shares the clip area, so its thickness comes out of the wrap
        // width (matching what autoresizing produces on window resize).
        scrollView.tile()
        let width = max(0, scrollView.contentView.bounds.width - ruler.ruleThickness)
        textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
        ruler.needsDisplay = true
    }

    // MARK: - Appearance (shared with terminals — see PaneContent)

    var initialBackgroundColor: NSColor {
        Theme.bg
    }

    func applyFont(_ font: NSFont) {
        textView.font = font
        ruler.updateThickness()
        ruler.needsDisplay = true
    }

    func applyTextColor(_ color: NSColor) {
        baseTextColor = color
        textView.textColor = color
        textView.insertionPointColor = color
        ruler.textColor = color.withAlphaComponent(0.4)
        ruler.needsDisplay = true
        // textColor repaints the whole document in the base color; put the
        // syntax colors back on top.
        applySyntaxAttributes()
        rebuildMinimap()
    }

    func applyBackground(_ color: NSColor) {
        textView.backgroundColor = color
        ruler.gutterBackground = color
        ruler.needsDisplay = true
        minimap.backgroundColor = color
    }

    func teardown() {
        NotificationCenter.default.removeObserver(self)
    }
}
