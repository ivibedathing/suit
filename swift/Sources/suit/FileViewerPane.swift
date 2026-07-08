import Cocoa

// Read-only file viewing inside the pane tree (ROADMAP Phase 1): line numbers,
// go-to-line, jump-to-line from the fuzzy opener / terminal links, syntax
// highlighting and a minimap (Phase 3). Deliberately not an editor — selection
// and copy only.
//
// The gutter (LineNumberRulerView), the text view (ViewerTextView), and the
// root container (ViewerContainerView) live in their own files; syntax/minimap
// wiring is in FileViewerPane+Highlighting.swift and the blame gutter, file
// history and bookmarks in FileViewerPane+Blame.swift.
final class FileViewerPaneContent: NSObject, FileBackedPaneContent {
    weak var pane: Pane?
    weak var tab: Tab?

    let scrollView = NSScrollView(frame: .zero)
    let textView: ViewerTextView
    let ruler: LineNumberRulerView
    let minimap = MinimapView(frame: .zero)
    private var container: ViewerContainerView!

    private(set) var filePath: String?
    var lineStarts: [Int] = [0]
    var syntaxSpans: [SyntaxSpan] = []
    var baseTextColor: NSColor = .textColor

    // MARK: - Editing (ROADMAP Phase 37)

    // Saved-vs-buffer tracking; the pure decisions live in FileEdit.swift.
    var editState = FileEditState()
    // True only when a real text file is loaded — the error placeholders
    // (binary / too large / unreadable) stay read-only.
    var isEditableFile = false
    // Debounced autosave (the NotesStore pattern) and debounced re-highlight so
    // colouring doesn't run on every keystroke.
    var autosaveTimer: Timer?
    var rehighlightTimer: Timer?
    // The file's on-disk mtime at our last load/save, to detect outside edits.
    var savedModificationDate: Date?
    // Set while we assign textView.string ourselves, so a programmatic reload
    // is never mistaken for a user edit.
    var isLoadingProgrammatically = false

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
        // Read-only until a real text file loads (Phase 37 — load() flips this
        // on for editable content, off for binary/too-large/error placeholders).
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
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
        textView.delegate = self
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
        // Editable viewer (Phase 37): when the app regains focus, check whether
        // the open file was rewritten underneath us (Claude / $EDITOR) and
        // reconcile — a clean buffer reloads, a dirty one prompts.
        NotificationCenter.default.addObserver(
            self, selector: #selector(appBecameActive),
            name: NSApplication.didBecomeActiveNotification, object: nil
        )
    }

    // MARK: - Changed regions (ROADMAP Phase 5)

    var changedLines = IndexSet()
    var jumpMarkerLine: Int?

    // MARK: - Blame gutter + file history (ROADMAP Phase 17)

    var blameVisible = false

    // MARK: - Bookmarks (ROADMAP Phase 22)

    var bookmarkedLines = IndexSet()

    // MARK: - Loading

    // Bumped per load; async highlight results from a superseded load drop out.
    var loadGeneration = 0

    func load(path: String, line: Int? = nil) {
        let standardized = (path as NSString).standardizingPath
        filePath = standardized
        loadGeneration += 1

        let text: String
        // Only real, in-bounds text is editable; the placeholders below stay
        // read-only so a save can never write a "Binary file" stub over a file.
        var editable = false
        if let data = FileManager.default.contents(atPath: standardized) {
            if data.count > Self.maxFileSize {
                text = "\(standardized)\n\nFile is too large for the viewer (\(data.count / (1024 * 1024)) MB)."
            } else if data.prefix(8192).contains(0) {
                text = "\(standardized)\n\nBinary file (\(data.count) bytes)."
            } else {
                text = String(decoding: data, as: UTF8.self)
                editable = true
            }
        } else {
            text = "\(standardized)\n\nCould not read file."
        }

        // Editing state (Phase 37): the loaded text becomes the clean baseline;
        // record the file's mtime so an outside rewrite is detectable.
        isEditableFile = editable
        textView.isEditable = editable
        editState.markLoaded(text)
        savedModificationDate = modificationDate(ofPath: standardized)
        autosaveTimer?.invalidate(); autosaveTimer = nil
        rehighlightTimer?.invalidate(); rehighlightTimer = nil

        isLoadingProgrammatically = true
        textView.string = text
        isLoadingProgrammatically = false
        // Fresh document — don't let undo reach back into a previous file's edits.
        textView.undoManager?.removeAllActions()
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
        // A reload starts clean — drop any leftover dirty indicator.
        tab?.contentDirtyDidChange(false)
        pane?.refreshChrome()

        if let line {
            jump(toLine: line)
        }
    }

    func recomputeLineStarts(for text: String) {
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
    func applyWrapWidth() {
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
        autosaveTimer?.invalidate()
        rehighlightTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }
}
