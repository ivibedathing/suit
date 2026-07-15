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
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let copyItem = menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        copyItem.isEnabled = selectedRange().length > 0
        return menu
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
        filePath = standardized
        if let data = FileManager.default.contents(atPath: standardized) {
            source = String(decoding: data, as: UTF8.self)
        } else {
            source = "Could not read \(standardized)."
        }
        rerender()
        tab?.contentTitleDidChange((standardized as NSString).lastPathComponent)
    }

    @objc private func modeChanged(_ sender: Any?) {
        rawMode = modePicker.selectedSegment == 1
        rerender()
    }

    private func rerender() {
        let attributed: NSAttributedString
        if rawMode {
            attributed = MarkdownRenderer.rawHighlighted(
                source, font: baseFont, textColor: baseTextColor
            )
        } else {
            attributed = MarkdownRenderer.render(
                source, baseFont: baseFont, textColor: baseTextColor, baseDir: workingDirectory
            )
        }
        textView.textStorage?.setAttributedString(attributed)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        updateInsets()
        loadRemoteImages()
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
    }
}
