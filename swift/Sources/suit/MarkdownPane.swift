import Cocoa

// Markdown preview tab: renders `.md`/`.markdown` as a formatted, read-only
// document — a centered reading column (max ~720pt, like GitHub/Typora) set
// in proportional document type (16pt floor, scaling with the pane font) with
// headings over hairline rules, joined paragraphs, nested lists and task
// checkboxes, full-width code-block backgrounds (fences colored by
// SyntaxHighlighter), bar-quoted blockquotes, pipe tables, images — local and
// remote, `![...]()` blocks, inline badges, and raw `<img>` tags — and
// inline emphasis/code/strikethrough/links (the parser itself is
// MarkdownRenderer.swift, with MarkdownImageLoader). A toggle flips rendered ↔ raw;
// raw is the plain highlighted source, the same surface a code file gets in
// the viewer. Deliberately read-only.

final class MarkdownTextView: NSTextView {
    /// Called with a `<details>` id when its summary line is clicked.
    var onDetailsToggle: ((Int) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let copyItem = menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        copyItem.isEnabled = selectedRange().length > 0
        return menu
    }

    // A click on a summary line toggles its disclosure instead of starting a
    // selection. Hit-testing goes through the glyph's own rect — the plain
    // character-index lookup snaps to the nearest glyph, so clicking the empty
    // space beside a summary would toggle it from across the column.
    override func mouseDown(with event: NSEvent) {
        guard let id = detailsID(at: event) else {
            super.mouseDown(with: event)
            return
        }
        onDetailsToggle?(id)
    }

    private func detailsID(at event: NSEvent) -> Int? {
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0
        else { return nil }
        var point = convert(event.locationInWindow, from: nil)
        point.x -= textContainerOrigin.x
        point.y -= textContainerOrigin.y
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(for: point, in: textContainer,
                                             fractionOfDistanceThroughGlyph: &fraction)
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1),
                                              in: textContainer)
        guard rect.contains(point) else { return nil }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        guard index < storage.length else { return nil }
        return storage.attribute(MarkdownRenderer.detailsIDKey, at: index, effectiveRange: nil) as? Int
    }
}

final class MarkdownPaneContent: NSObject, FileBackedPaneContent, NSTextViewDelegate {
    weak var pane: Pane?
    weak var tab: Tab?

    private let containerView = NSView(frame: .zero)
    private let modePicker = NSSegmentedControl(labels: ["Rendered", "Raw"], trackingMode: .selectOne, target: nil, action: nil)
    private let scrollView = NSScrollView(frame: .zero)
    private let textView = MarkdownTextView(frame: .zero)

    private static let headerHeight: CGFloat = 30
    // The rendered document reads in a centered column, the way markdown apps
    // and GitHub lay out prose — capped width, margins grow with the pane.
    private static let maxColumnWidth: CGFloat = 720
    private static let minColumnMargin: CGFloat = 28

    private(set) var filePath: String?
    private var source = ""
    private var rawMode = false
    // `<details>` ids the reader has toggled away from their `open` default,
    // keyed by the source line of the tag. Kept on the pane rather than in the
    // text storage, so the re-render behind a theme or font change — which
    // rebuilds the storage from the same source — preserves expansion for free.
    private var flippedDetails: Set<Int> = []
    // Live reload: a README being rewritten under an open tab re-renders in
    // place. The stamp filters the event bursts a generator produces down to the
    // writes that actually changed something.
    private var fileWatcher: FileWatcher?
    private var fileStamp: FileStamp?
    // Block-based on purpose: a target/selector timer would retain the pane and
    // make teardown() the only thing between us and leaking it.
    private var animationTimer: Timer?
    private var animationClock: TimeInterval = 0
    private var nextFrameDue: [Int: TimeInterval] = [:]
    private var baseFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private var baseTextColor: NSColor = Theme.textPrimary
    private var background = Theme.bg

    var view: NSView { containerView }
    var focusTarget: NSView { textView }
    var defaultTitle: String { "Markdown" }
    var workingDirectory: String? {
        filePath.map { ($0 as NSString).deletingLastPathComponent }
    }
    var initialBackgroundColor: NSColor { background }

    override init() {
        super.init()

        // Ground the whole content (header strip included) in the chrome color so
        // the mode toggle reads as a toolbar, not a transparent gap.
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = Theme.bg.cgColor

        // The rendered document uses NSTextTable/NSTextBlock (tables, code
        // backgrounds, quote bars), which only lay out on the TextKit 1 stack;
        // touching layoutManager opts the view out of TextKit 2 up front.
        _ = textView.layoutManager

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.drawsBackground = true
        textView.linkTextAttributes = [
            .foregroundColor: Theme.accent,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        textView.delegate = self
        textView.onDetailsToggle = { [weak self] id in self?.toggleDetails(id) }

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        containerView.addSubview(scrollView)

        modePicker.selectedSegment = 0
        modePicker.controlSize = .small
        modePicker.target = self
        modePicker.action = #selector(modeChanged)
        containerView.addSubview(modePicker)

        containerView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(layoutContents),
            name: NSView.frameDidChangeNotification, object: containerView
        )
    }

    func load(path: String, line: Int?) {
        let standardized = (path as NSString).standardizingPath
        // Expansion is keyed by source line, so it means nothing once the
        // source changes.
        if standardized != filePath { flippedDetails.removeAll() }
        filePath = standardized
        readSource(standardized)
        rerender()
        tab?.contentTitleDidChange((standardized as NSString).lastPathComponent)

        fileWatcher?.stop()
        fileWatcher = FileWatcher(path: standardized) { [weak self] in
            self?.reloadFromDisk()
        }
    }

    private func readSource(_ path: String) {
        fileStamp = FileStamp(path: path)
        if let data = FileManager.default.contents(atPath: path) {
            source = String(decoding: data, as: UTF8.self)
        } else {
            source = "Could not read \(path)."
        }
    }

    // The file changed underneath the open tab. Nothing here is editable, so
    // there's never a conflict to resolve — re-read and re-render, holding the
    // scroll position and the `<details>` toggles so a reader mid-document isn't
    // thrown back to the top by someone else's write.
    private func reloadFromDisk() {
        guard let filePath, FileStamp.changed(from: fileStamp, to: FileStamp(path: filePath)) else { return }
        let fraction = scrollFraction
        readSource(filePath)
        rerender()
        restore(scrollFraction: fraction)
    }

    @objc private func modeChanged(_ sender: Any?) {
        rawMode = modePicker.selectedSegment == 1
        rerender()
    }

    // Toggling re-renders the whole document — a README is milliseconds, and it
    // avoids surgery on a live text storage. Hold the scroll position across it
    // so expanding something below the fold doesn't jump the reader.
    private func toggleDetails(_ id: Int) {
        if flippedDetails.contains(id) {
            flippedDetails.remove(id)
        } else {
            flippedDetails.insert(id)
        }
        let fraction = scrollFraction
        rerender()
        restore(scrollFraction: fraction)
    }

    private func rerender() {
        let attributed: NSAttributedString
        if rawMode {
            attributed = MarkdownRenderer.rawHighlighted(
                source, font: baseFont, textColor: baseTextColor
            )
        } else {
            attributed = MarkdownRenderer.render(
                source, baseFont: baseFont, textColor: baseTextColor, baseDir: workingDirectory,
                flippedDetails: flippedDetails
            )
        }
        textView.textStorage?.setAttributedString(attributed)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        updateInsets()
        loadRemoteImages()
        syncAnimation()
    }

    // MARK: - Animated images

    // One timer per pane drives every animated GIF in the document, rather than
    // one per cell: the cells are replaced wholesale on each rerender() and by
    // the remote-image swap, so per-cell timers would need a teardown protocol
    // to avoid outliving their cell. Nothing retains the cells here — the timer
    // re-finds them by attribute each tick, and dropping the storage drops them.
    private func syncAnimation() {
        let cells = animatedCells()
        guard !rawMode, !cells.isEmpty else {
            stopAnimation()
            return
        }
        guard animationTimer == nil else { return }
        // Frame durations vary per GIF and per frame; tick at a fixed rate and
        // let each cell advance when its own frame is due. Coalescing many GIFs
        // onto one clock costs a little frame-time precision and saves a timer
        // per image.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.tickAnimation()
        }
        // .common so a GIF keeps playing while the reader drags the scroller.
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        animationClock = 0
        nextFrameDue = [:]
    }

    private func tickAnimation() {
        guard !rawMode else {
            stopAnimation()
            return
        }
        let cells = animatedCells()
        // Every GIF gone — a rerender or the raw toggle swapped the storage.
        guard !cells.isEmpty else {
            stopAnimation()
            return
        }
        animationClock += 0.05
        for (range, cell) in cells where animationClock >= (nextFrameDue[range.location] ?? 0) {
            nextFrameDue[range.location] = animationClock + cell.advance()
            textView.layoutManager?.invalidateDisplay(forCharacterRange: range)
        }
    }

    // Re-found by attribute every tick rather than cached: the remote-image
    // swap and rerender() both move ranges, and a stale range would draw the
    // wrong run.
    private func animatedCells() -> [(NSRange, AnimatedImageCell)] {
        guard let storage = textView.textStorage else { return [] }
        var found: [(NSRange, AnimatedImageCell)] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let cell = (value as? NSTextAttachment)?.attachmentCell as? AnimatedImageCell {
                found.append((range, cell))
            }
        }
        return found
    }

    // MARK: - Remote images

    // The renderer leaves a dim placeholder run for every remote image, tagged
    // with the URL. Fetch each one (shared cache, so re-renders are free) and
    // swap the placeholder for the bitmap once it arrives. Failed fetches keep
    // the placeholder — the alt text stays readable.
    private func loadRemoteImages() {
        guard !rawMode, let storage = textView.textStorage else { return }
        var urls: Set<URL> = []
        storage.enumerateAttribute(
            MarkdownRenderer.remoteImageURLKey,
            in: NSRange(location: 0, length: storage.length)
        ) { value, _, _ in
            if let url = value as? URL { urls.insert(url) }
        }
        for url in urls {
            MarkdownImageLoader.shared.fetch(url) { [weak self] image in
                guard let image else { return }
                self?.replaceImagePlaceholders(url: url, image: image)
            }
        }
    }

    private func replaceImagePlaceholders(url: URL, image: NSImage) {
        guard !rawMode, let storage = textView.textStorage else { return }
        // Re-find the placeholders by attribute rather than trusting saved
        // ranges — the document may have been re-rendered since the fetch began.
        var found: [(NSRange, [NSAttributedString.Key: Any])] = []
        storage.enumerateAttribute(
            MarkdownRenderer.remoteImageURLKey,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            if (value as? URL) == url {
                found.append((range, storage.attributes(at: range.location, effectiveRange: nil)))
            }
        }
        guard !found.isEmpty else { return }
        storage.beginEditing()
        for (range, attrs) in found.reversed() {
            let maxWidth = (attrs[MarkdownRenderer.imageMaxWidthKey] as? NSNumber)
                .map { CGFloat(truncating: $0) }
            let replacement = NSMutableAttributedString(
                attributedString: MarkdownRenderer.attachmentString(for: image, maxWidth: maxWidth)
            )
            // Keep what the placeholder inherited from its context: the link
            // wrapping a badge, and the block/paragraph spacing around it.
            var carried: [NSAttributedString.Key: Any] = [:]
            if let link = attrs[.link] { carried[.link] = link }
            if let para = attrs[.paragraphStyle] { carried[.paragraphStyle] = para }
            if !carried.isEmpty {
                replacement.addAttributes(carried, range: NSRange(location: 0, length: replacement.length))
            }
            storage.replaceCharacters(in: range, with: replacement)
        }
        storage.endEditing()
        // A remote GIF only becomes animatable now, once its bitmap has landed.
        syncAnimation()
    }

    // Center the rendered column: the horizontal inset absorbs whatever width
    // exceeds the reading measure. Raw mode keeps the code-viewer's tight
    // gutter.
    private func updateInsets() {
        let width = scrollView.contentSize.width > 0 ? scrollView.contentSize.width : containerView.bounds.width
        let inset: NSSize
        if rawMode {
            inset = NSSize(width: 12, height: 12)
        } else {
            let horizontal = max(Self.minColumnMargin, (width - Self.maxColumnWidth) / 2)
            inset = NSSize(width: horizontal, height: 32)
        }
        if textView.textContainerInset != inset {
            textView.textContainerInset = inset
        }
    }

    @objc private func layoutContents() {
        let bounds = containerView.bounds
        let contentHeight = max(0, bounds.height - Self.headerHeight)
        modePicker.sizeToFit()
        modePicker.frame.origin = NSPoint(
            x: bounds.width - modePicker.frame.width - 8,
            y: contentHeight + (Self.headerHeight - modePicker.frame.height) / 2
        )
        scrollView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: contentHeight)
        updateInsets()
    }

    // MARK: - Links (rendered mode)

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let target = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
        guard !target.isEmpty else { return false }
        if let url = URL(string: target), let scheme = url.scheme,
           ["http", "https", "mailto", "ftp"].contains(scheme.lowercased()) {
            NSWorkspace.shared.open(url)
            return true
        }
        // A bare path — resolve it relative to the markdown file and open it as
        // its own tab, the same as a Cmd-clicked terminal link.
        let base = (filePath as NSString?)?.deletingLastPathComponent ?? ""
        let resolved = target.hasPrefix("/")
            ? target
            : (base as NSString).appendingPathComponent(target)
        let standardized = (resolved as NSString).standardizingPath
        if FileManager.default.fileExists(atPath: standardized) {
            pane?.openFileLink(path: standardized, line: nil)
            return true
        }
        return false
    }

    // MARK: - State restoration

    var scrollFraction: Double {
        guard let documentView = scrollView.documentView else { return 0 }
        let docHeight = documentView.frame.height
        guard docHeight > 0 else { return 0 }
        return Double(scrollView.contentView.bounds.minY / docHeight)
    }

    func restore(scrollFraction: Double) {
        guard let documentView = scrollView.documentView else { return }
        let docHeight = documentView.frame.height
        let target = max(0, CGFloat(scrollFraction) * docHeight)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: target))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: - Appearance

    func applyFont(_ font: NSFont) {
        baseFont = font
        rerender()
    }

    func applyTextColor(_ color: NSColor) {
        baseTextColor = color
        rerender()
    }

    func applyBackground(_ color: NSColor) {
        background = color
        textView.backgroundColor = color
    }

    // Live theme switch: re-ground the header strip, re-tint links, and
    // re-render so the rendered/raw attributed string picks up the new tokens
    // (the pane re-pushes the background separately via applyBackground).
    func reapplyTheme() {
        containerView.layer?.backgroundColor = Theme.bg.cgColor
        textView.linkTextAttributes = [
            .foregroundColor: Theme.accent,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        rerender()
    }

    func teardown() {
        NotificationCenter.default.removeObserver(self)
        fileWatcher?.stop()
        fileWatcher = nil
        stopAnimation()
    }
}
