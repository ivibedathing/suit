import Cocoa

// Markdown preview tab: renders `.md`/`.markdown` as a formatted, read-only
// document — a centered reading column (max ~720pt, like GitHub/Typora) set
// in proportional document type (16pt floor, scaling with the pane font) with
// headings over hairline rules, joined paragraphs, nested lists and task
// checkboxes, full-width code-block backgrounds (fences colored by
// SyntaxHighlighter), bar-quoted blockquotes, pipe tables, images — local and
// remote, `![...]()` blocks, inline badges, and raw `<img>` tags — and
// inline emphasis/code/strikethrough/links. A toggle flips rendered ↔ raw;
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

// Fetches and memory-caches remote markdown images. Shared across panes so a
// README's badges download once per app run; failures are remembered so theme
// and font re-renders don't re-hit dead URLs. Completions land on main.
final class MarkdownImageLoader {
    static let shared = MarkdownImageLoader()

    private let cache = NSCache<NSURL, NSImage>()
    private var failed: Set<URL> = []
    private var inFlight: [URL: [(NSImage?) -> Void]] = [:]

    func cached(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    func fetch(_ url: URL, completion: @escaping (NSImage?) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        if let hit = cached(url) { completion(hit); return }
        if failed.contains(url) { completion(nil); return }
        if inFlight[url] != nil { inFlight[url]?.append(completion); return }
        inFlight[url] = [completion]
        URLSession.shared.dataTask(with: url) { data, _, _ in
            var image = data.flatMap { NSImage(data: $0) }
            if let img = image, img.size.width <= 0 { image = nil }
            DispatchQueue.main.async {
                if let image {
                    self.cache.setObject(image, forKey: url as NSURL)
                } else {
                    self.failed.insert(url)
                }
                for callback in self.inFlight.removeValue(forKey: url) ?? [] { callback(image) }
            }
        }.resume()
    }
}

// A compact line-based Markdown → NSAttributedString renderer. Not a full
// CommonMark implementation — ATX/setext headings, nested lists, task lists,
// fenced/inline code, blockquotes, pipe tables, rules, images, emphasis,
// strikethrough, and links, which covers READMEs and design notes. Layout
// leans on NSTextBlock/NSTextTable for the block chrome (code backgrounds,
// quote bars, table grids, full-width rules), so the result reads like other
// markdown apps' previews. The raw mode reuses the viewer's SyntaxHighlighter,
// so the two modes share one look.
enum MarkdownRenderer {
    static func rawHighlighted(_ text: String, font: NSFont, textColor: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: textColor]
        )
        guard (text as NSString).length <= SyntaxHighlighter.maxLength else { return result }
        for span in SyntaxHighlighter.highlight(text: text, language: .markdown)
        where NSMaxRange(span.range) <= result.length {
            result.addAttribute(.foregroundColor, value: span.kind.color, range: span.range)
        }
        return result
    }

    static func render(_ text: String, baseFont: NSFont, textColor: NSColor, baseDir: String? = nil) -> NSAttributedString {
        // Reading size: prose renders larger than the terminal font it
        // inherits, the way documentation surfaces do, and never below a 16pt
        // floor — the default 13pt terminal font should still yield
        // comfortable document type. ⌘= / ⌘- keep scaling it past the floor.
        let size = max(baseFont.pointSize + 3, 16)
        let body = NSFont.systemFont(ofSize: size)
        let mono = NSFont.monospacedSystemFont(ofSize: size - 2, weight: .regular)
        let out = NSMutableAttributedString()

        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block.
            if trimmed.hasPrefix("```") {
                let info = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i])
                    i += 1
                }
                if i < lines.count { i += 1 } // closing fence
                out.append(codeBlock(code.joined(separator: "\n"), info: info, size: size, font: mono, textColor: textColor))
                continue
            }

            // Horizontal rule.
            if isRule(trimmed) {
                out.append(rule(spacingBefore: size * 0.7, spacingAfter: size * 1.0))
                i += 1
                continue
            }

            // ATX heading.
            if let (level, content) = heading(trimmed) {
                out.append(headingText(content, level: level, size: size, textColor: textColor, mono: mono))
                i += 1
                continue
            }

            // Blockquote (one or more consecutive `>` lines).
            if trimmed.hasPrefix(">") {
                var quote: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    let q = lines[i].trimmingCharacters(in: .whitespaces)
                    quote.append(String(q.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                out.append(blockquote(quote, size: size, mono: mono))
                continue
            }

            // Pipe table: a header row over a `---|---` separator.
            if trimmed.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                let header = tableCells(trimmed)
                let alignments = tableCells(lines[i + 1]).map(cellAlignment)
                i += 2
                var rows: [[String]] = []
                while i < lines.count {
                    let rowLine = lines[i].trimmingCharacters(in: .whitespaces)
                    guard !rowLine.isEmpty, rowLine.contains("|") else { break }
                    rows.append(tableCells(rowLine))
                    i += 1
                }
                out.append(table(header: header, alignments: alignments, rows: rows,
                                 size: size, textColor: textColor, mono: mono))
                continue
            }

            // List item (bullet, ordered, or task). Indented continuation
            // lines join the item the way hard-wrapped paragraph lines join —
            // a wrapped bullet stays one bullet.
            if let item = listItem(line) {
                var content = item.content
                var j = i + 1
                while j < lines.count,
                      lines[j].first == " " || lines[j].first == "\t",
                      isParagraphContinuation(lines[j], next: j + 1 < lines.count ? lines[j + 1] : nil) {
                    content += " " + lines[j].trimmingCharacters(in: .whitespaces)
                    j += 1
                }
                let indent = 4 + CGFloat(item.level) * 20
                let para = NSMutableParagraphStyle()
                para.firstLineHeadIndent = indent
                para.headIndent = indent + 24
                para.tabStops = [NSTextTab(textAlignment: .left, location: indent + 24)]
                para.lineSpacing = size * 0.3
                para.paragraphSpacing = size * 0.35
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: body, .foregroundColor: textColor, .paragraphStyle: para,
                ]
                var markerAttrs = attrs
                var marker = item.marker
                if let checked = item.checked {
                    marker = checked ? "☑" : "☐"
                    markerAttrs[.foregroundColor] = checked ? Theme.accent : Theme.textDim
                } else if !marker.hasSuffix(".") {
                    markerAttrs[.foregroundColor] = Theme.textDim
                }
                out.append(NSAttributedString(string: marker + "\t", attributes: markerAttrs))
                out.append(inline(content, base: attrs, size: size, textColor: textColor, mono: mono, baseDir: baseDir))
                out.append(NSAttributedString(string: "\n", attributes: attrs))
                i = j
                continue
            }

            // Blank line — most vertical rhythm comes from paragraph spacing,
            // so a source blank contributes only a sliver.
            if trimmed.isEmpty {
                out.append(NSAttributedString(string: "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: size * 0.35),
                ]))
                i += 1
                continue
            }

            // Block image on its own line — `![alt](src)` or raw `<img>` tags,
            // local or remote.
            if let image = imageLine(trimmed, baseDir: baseDir, size: size) {
                out.append(image)
                i += 1
                continue
            }

            // Setext heading: a text line underlined with === or ---.
            if i + 1 < lines.count, let level = setextLevel(lines[i + 1].trimmingCharacters(in: .whitespaces)) {
                out.append(headingText(trimmed, level: level, size: size, textColor: textColor, mono: mono))
                i += 2
                continue
            }

            // Plain paragraph: hard-wrapped source lines join into one
            // paragraph, the way markdown means them.
            var parts = [trimmed]
            i += 1
            while i < lines.count, isParagraphContinuation(lines[i], next: i + 1 < lines.count ? lines[i + 1] : nil) {
                parts.append(lines[i].trimmingCharacters(in: .whitespaces))
                i += 1
            }
            let para = NSMutableParagraphStyle()
            para.lineSpacing = size * 0.4
            para.paragraphSpacing = size * 0.7
            let attrs: [NSAttributedString.Key: Any] = [
                .font: body, .foregroundColor: textColor, .paragraphStyle: para,
            ]
            out.append(inline(parts.joined(separator: " "), base: attrs, size: size, textColor: textColor, mono: mono, baseDir: baseDir))
            out.append(NSAttributedString(string: "\n", attributes: attrs))
        }
        return out
    }

    // MARK: - Block helpers

    private static func heading(_ line: String) -> (Int, String)? {
        var level = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == "#", level < 6 {
            level += 1
            idx = line.index(after: idx)
        }
        guard level > 0, idx < line.endIndex, line[idx] == " " else { return nil }
        return (level, String(line[line.index(after: idx)...]))
    }

    private static func headingText(_ content: String, level: Int, size: CGFloat,
                                    textColor: NSColor, mono: NSFont) -> NSAttributedString {
        let scale: CGFloat = [2.0, 1.5, 1.25, 1.05, 0.95, 0.85][min(level - 1, 5)]
        let weight: NSFont.Weight = level <= 2 ? .bold : .semibold
        let font = NSFont.systemFont(ofSize: round(size * scale), weight: weight)
        let para = NSMutableParagraphStyle()
        para.paragraphSpacingBefore = size * (level <= 2 ? 1.2 : 1.0)
        para.paragraphSpacing = level <= 2 ? size * 0.3 : size * 0.5
        let color = level == 6 ? Theme.textDim : textColor
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: para,
        ]
        let result = NSMutableAttributedString(
            attributedString: inline(content, base: attrs, size: size, textColor: color, mono: mono)
        )
        result.append(NSAttributedString(string: "\n", attributes: attrs))
        // H1/H2 sit on a hairline rule, GitHub-style.
        if level <= 2 {
            result.append(rule(spacingBefore: 0, spacingAfter: size * 0.7))
        }
        return result
    }

    private static func isRule(_ trimmed: String) -> Bool {
        trimmed == "---" || trimmed == "***" || trimmed == "___"
    }

    private static func setextLevel(_ trimmed: String) -> Int? {
        guard trimmed.count >= 3 else { return nil }
        if trimmed.allSatisfy({ $0 == "=" }) { return 1 }
        if trimmed.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    // A full-width hairline drawn as a text block's bottom border, so it spans
    // the column instead of just its glyphs.
    private static func rule(spacingBefore: CGFloat, spacingAfter: CGFloat) -> NSAttributedString {
        let block = NSTextBlock()
        block.setValue(100, type: .percentageValueType, for: .width)
        block.setBorderColor(Theme.hairline, for: .maxY)
        block.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
        let para = NSMutableParagraphStyle()
        para.textBlocks = [block]
        para.paragraphSpacingBefore = spacingBefore
        para.paragraphSpacing = spacingAfter
        return NSAttributedString(string: "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 1), .paragraphStyle: para,
        ])
    }

    private static func blockquote(_ entries: [String], size: CGFloat, mono: NSFont) -> NSAttributedString {
        // Group `>` lines into paragraphs on empty entries; every paragraph
        // (including the spacers between them) carries the same left-bar block
        // so the bar runs unbroken down the quote.
        var paragraphs: [[String]] = [[]]
        for entry in entries {
            if entry.isEmpty {
                if !(paragraphs.last?.isEmpty ?? true) { paragraphs.append([]) }
            } else {
                paragraphs[paragraphs.count - 1].append(entry)
            }
        }
        paragraphs.removeAll { $0.isEmpty }

        func bar() -> NSTextBlock {
            let block = NSTextBlock()
            block.setValue(100, type: .percentageValueType, for: .width)
            block.setBorderColor(Theme.hairline, for: .minX)
            block.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
            block.setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
            return block
        }

        let result = NSMutableAttributedString()
        for (index, group) in paragraphs.enumerated() {
            let para = NSMutableParagraphStyle()
            para.textBlocks = [bar()]
            para.lineSpacing = size * 0.25
            if index == 0 { para.paragraphSpacingBefore = size * 0.5 }
            if index == paragraphs.count - 1 { para.paragraphSpacing = size * 0.8 }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size), .foregroundColor: Theme.textDim,
                .paragraphStyle: para,
            ]
            result.append(inline(group.joined(separator: " "), base: attrs, size: size, textColor: Theme.textDim, mono: mono))
            result.append(NSAttributedString(string: "\n", attributes: attrs))
            if index < paragraphs.count - 1 {
                // Bar-carrying spacer between quote paragraphs.
                let spacerPara = NSMutableParagraphStyle()
                spacerPara.textBlocks = [bar()]
                result.append(NSAttributedString(string: "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: size * 0.5), .paragraphStyle: spacerPara,
                ]))
            }
        }
        return result
    }

    private static func listItem(_ line: String) -> (marker: String, content: String, level: Int, checked: Bool?)? {
        var indent = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == " " || line[idx] == "\t" {
            indent += line[idx] == "\t" ? 4 : 1
            idx = line.index(after: idx)
        }
        let trimmed = line[idx...]
        let level = min(indent / 2, 5)
        if let first = trimmed.first, "-*+".contains(first), trimmed.dropFirst().first == " " {
            var content = String(trimmed.dropFirst(2))
            var checked: Bool?
            if content.hasPrefix("[ ] ") {
                checked = false
                content = String(content.dropFirst(4))
            } else if content.lowercased().hasPrefix("[x] ") {
                checked = true
                content = String(content.dropFirst(4))
            }
            let bullets = ["•", "◦", "▪"]
            return (bullets[level % bullets.count], content, level, checked)
        }
        // Ordered: digits then `. ` or `) `.
        var digits = ""
        var rest = trimmed
        while let c = rest.first, c.isNumber {
            digits.append(c)
            rest = rest.dropFirst()
        }
        if !digits.isEmpty, rest.first == "." || rest.first == ")", rest.dropFirst().first == " " {
            return (digits + ".", String(rest.dropFirst(2)), level, nil)
        }
        return nil
    }

    // Whether a source line extends the current paragraph rather than starting
    // a new block.
    private static func isParagraphContinuation(_ line: String, next: String?) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return false }
        if trimmed.hasPrefix("```") || trimmed.hasPrefix(">") || trimmed.hasPrefix("#") { return false }
        if isRule(trimmed) || setextLevel(trimmed) != nil { return false }
        if listItem(line) != nil { return false }
        if trimmed.contains("|"), let next, isTableSeparator(next) { return false }
        return true
    }

    private static func codeBlock(_ code: String, info: String, size: CGFloat,
                                  font: NSFont, textColor: NSColor) -> NSAttributedString {
        let display = (code.isEmpty ? " " : code) + "\n"
        let result = NSMutableAttributedString(string: display, attributes: [
            .font: font, .foregroundColor: textColor,
        ])
        if let language = fenceLanguage(info), (code as NSString).length <= SyntaxHighlighter.maxLength {
            for span in SyntaxHighlighter.highlight(text: code, language: language)
            where NSMaxRange(span.range) <= (code as NSString).length {
                result.addAttribute(.foregroundColor, value: span.kind.color, range: span.range)
            }
        }
        // Each line is its own paragraph, so each carries a background block;
        // stacked flush (no paragraph spacing inside) they read as one padded
        // full-width card, with the vertical padding on the first/last lines.
        let ns = result.string as NSString
        var location = 0
        var first = true
        while location < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
            let last = NSMaxRange(lineRange) >= ns.length
            let block = NSTextBlock()
            block.setValue(100, type: .percentageValueType, for: .width)
            block.backgroundColor = Theme.raised
            block.setWidth(14, type: .absoluteValueType, for: .padding, edge: .minX)
            block.setWidth(14, type: .absoluteValueType, for: .padding, edge: .maxX)
            if first { block.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minY) }
            if last { block.setWidth(10, type: .absoluteValueType, for: .padding, edge: .maxY) }
            let para = NSMutableParagraphStyle()
            para.textBlocks = [block]
            if first { para.paragraphSpacingBefore = size * 0.5 }
            if last { para.paragraphSpacing = size * 0.9 }
            result.addAttribute(.paragraphStyle, value: para, range: lineRange)
            first = false
            location = NSMaxRange(lineRange)
        }
        return result
    }

    // MARK: - Tables

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") else { return false }
        return trimmed.allSatisfy { "|-: \t".contains($0) }
    }

    private static func tableCells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func cellAlignment(_ separatorCell: String) -> NSTextAlignment {
        let leading = separatorCell.hasPrefix(":")
        let trailing = separatorCell.hasSuffix(":")
        if leading && trailing { return .center }
        if trailing { return .right }
        return .left
    }

    private static func table(header: [String], alignments: [NSTextAlignment], rows: [[String]],
                              size: CGFloat, textColor: NSColor, mono: NSFont) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let textTable = NSTextTable()
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        guard columns > 0 else { return out }
        textTable.numberOfColumns = columns
        textTable.collapsesBorders = true

        for (rowIndex, row) in ([header] + rows).enumerated() {
            for column in 0..<columns {
                let cellBlock = NSTextTableBlock(
                    table: textTable, startingRow: rowIndex, rowSpan: 1,
                    startingColumn: column, columnSpan: 1
                )
                cellBlock.setBorderColor(Theme.hairline)
                cellBlock.setWidth(1, type: .absoluteValueType, for: .border)
                cellBlock.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
                cellBlock.setWidth(10, type: .absoluteValueType, for: .padding, edge: .maxX)
                cellBlock.setWidth(5, type: .absoluteValueType, for: .padding, edge: .minY)
                cellBlock.setWidth(5, type: .absoluteValueType, for: .padding, edge: .maxY)
                if rowIndex == 0 { cellBlock.backgroundColor = Theme.raised }

                let para = NSMutableParagraphStyle()
                para.textBlocks = [cellBlock]
                if column < alignments.count { para.alignment = alignments[column] }
                let font = rowIndex == 0
                    ? NSFont.systemFont(ofSize: size - 1, weight: .semibold)
                    : NSFont.systemFont(ofSize: size - 1)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font, .foregroundColor: textColor, .paragraphStyle: para,
                ]
                let content = column < row.count && !row[column].isEmpty ? row[column] : " "
                let cell = NSMutableAttributedString(
                    attributedString: inline(content, base: attrs, size: size, textColor: textColor, mono: mono)
                )
                cell.append(NSAttributedString(string: "\n", attributes: attrs))
                cell.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: cell.length))
                out.append(cell)
            }
        }
        // Breathing room below the grid.
        out.append(NSAttributedString(string: "\n", attributes: [
            .font: NSFont.systemFont(ofSize: size * 0.5),
        ]))
        return out
    }

    // MARK: - Images

    // Placeholder runs for remote images carry these: the pane fetches the URL
    // and swaps the run for the bitmap; the optional width (from an <img>
    // width attribute) caps the swapped-in image.
    static let remoteImageURLKey = NSAttributedString.Key("suit.markdown.remoteImageURL")
    static let imageMaxWidthKey = NSAttributedString.Key("suit.markdown.imageMaxWidth")

    // Images never exceed the reading column (720pt minus the code-block gutter).
    private static let imageColumnWidth: CGFloat = 680

    static func attachmentString(for image: NSImage, maxWidth: CGFloat?) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = image
        let cap = min(maxWidth ?? imageColumnWidth, imageColumnWidth)
        var bounds = image.size
        if bounds.width > cap {
            bounds = NSSize(width: cap, height: bounds.height * cap / bounds.width)
        }
        attachment.bounds = NSRect(origin: .zero, size: bounds)
        return NSAttributedString(attachment: attachment)
    }

    // A line that is nothing but images — `![alt](src)` or HTML starting with
    // `<` and containing `<img>` tags (the `<p align="center"><img …></p>`
    // README idiom) → the images as their own block, scaled into the column.
    // Unresolvable lines fall through to paragraph rendering.
    private static func imageLine(_ trimmed: String, baseDir: String?, size: CGFloat) -> NSAttributedString? {
        var fragments: [NSAttributedString] = []
        if trimmed.hasPrefix("<") {
            for spec in htmlImageSpecs(trimmed) {
                if let fragment = imageFragment(alt: spec.alt, src: spec.src, baseDir: baseDir,
                                                size: size, maxWidth: spec.width, base: [:]) {
                    fragments.append(fragment)
                }
            }
        } else if trimmed.hasPrefix("!["), trimmed.hasSuffix(")"),
                  let spec = imageSpec(trimmed), spec.rest.isEmpty,
                  let fragment = imageFragment(alt: spec.alt, src: spec.src, baseDir: baseDir,
                                               size: size, maxWidth: nil, base: [:]) {
            fragments.append(fragment)
        }
        guard !fragments.isEmpty else { return nil }

        let para = NSMutableParagraphStyle()
        para.paragraphSpacingBefore = size * 0.4
        para.paragraphSpacing = size * 0.8
        let result = NSMutableAttributedString()
        for (index, fragment) in fragments.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "  ")) }
            result.append(fragment)
        }
        result.append(NSAttributedString(string: "\n"))
        result.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: result.length))
        return result
    }

    // One image reference → its fragment: the bitmap itself when local (or an
    // already-fetched remote), a dim tagged placeholder when remote, nil when
    // unusable (missing file, non-http scheme).
    private static func imageFragment(alt: String, src: String, baseDir: String?, size: CGFloat,
                                      maxWidth: CGFloat?, base: [NSAttributedString.Key: Any]) -> NSAttributedString? {
        guard !src.isEmpty else { return nil }
        if src.contains("://") {
            guard let url = URL(string: src), let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return nil }
            if let cached = MarkdownImageLoader.shared.cached(url) {
                return attachmentFragment(cached, maxWidth: maxWidth, base: base)
            }
            var attrs = base
            attrs[.font] = italic(NSFont.systemFont(ofSize: max(size - 2, 11)))
            attrs[.foregroundColor] = Theme.textDim
            attrs[remoteImageURLKey] = url
            if let maxWidth { attrs[imageMaxWidthKey] = NSNumber(value: Double(maxWidth)) }
            let label = alt.isEmpty ? url.lastPathComponent : alt
            return NSAttributedString(string: "🖼 \(label)", attributes: attrs)
        }
        let path = src.hasPrefix("/")
            ? src
            : ((baseDir ?? "") as NSString).appendingPathComponent(src)
        let standardized = (path as NSString).standardizingPath
        guard let image = NSImage(contentsOfFile: standardized), image.size.width > 0 else { return nil }
        return attachmentFragment(image, maxWidth: maxWidth, base: base)
    }

    private static func attachmentFragment(_ image: NSImage, maxWidth: CGFloat?,
                                           base: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: attachmentString(for: image, maxWidth: maxWidth))
        var carried: [NSAttributedString.Key: Any] = [:]
        if let link = base[.link] { carried[.link] = link }
        if let para = base[.paragraphStyle] { carried[.paragraphStyle] = para }
        if !carried.isEmpty {
            result.addAttributes(carried, range: NSRange(location: 0, length: result.length))
        }
        return result
    }

    // The destination part of an image/link: strip an optional `"title"` and
    // surrounding whitespace.
    private static func imageSource(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        return trimmed.components(separatedBy: " ").first ?? trimmed
    }

    // `![alt](src)` or `![alt](src "title")` at the start of the text →
    // (alt, src, whatever follows the closing paren).
    private static func imageSpec(_ text: String) -> (alt: String, src: String, rest: Substring)? {
        guard text.hasPrefix("!["), let altClose = text.range(of: "](") else { return nil }
        let alt = String(text[text.index(text.startIndex, offsetBy: 2)..<altClose.lowerBound])
        guard let parenClose = text.range(of: ")", range: altClose.upperBound..<text.endIndex) else { return nil }
        let raw = String(text[altClose.upperBound..<parenClose.lowerBound]).trimmingCharacters(in: .whitespaces)
        let src = raw.components(separatedBy: " ").first ?? raw
        return (alt, src, text[parenClose.upperBound...])
    }

    // Every `<img …>` tag in an HTML line → (alt, src, width-attribute).
    private static func htmlImageSpecs(_ line: String) -> [(alt: String, src: String, width: CGFloat?)] {
        var specs: [(alt: String, src: String, width: CGFloat?)] = []
        var search = line.startIndex
        while let tagStart = line.range(of: "<img", options: .caseInsensitive,
                                        range: search..<line.endIndex)?.lowerBound {
            let tagEnd = line.range(of: ">", range: tagStart..<line.endIndex)?.upperBound ?? line.endIndex
            let tag = String(line[tagStart..<tagEnd])
            if let src = htmlAttribute("src", in: tag) {
                let width = htmlAttribute("width", in: tag).flatMap { Double($0) }.map { CGFloat($0) }
                specs.append((htmlAttribute("alt", in: tag) ?? "", src, width))
            }
            search = tagEnd
        }
        return specs
    }

    private static func htmlAttribute(_ name: String, in tag: String) -> String? {
        guard let attr = tag.range(of: "\(name)=", options: .caseInsensitive) else { return nil }
        let after = tag[attr.upperBound...]
        guard let quote = after.first, quote == "\"" || quote == "'" else {
            // Unquoted value: runs to the next space or tag end.
            let value = after.prefix { $0 != " " && $0 != ">" && $0 != "/" }
            return value.isEmpty ? nil : String(value)
        }
        let body = after.dropFirst()
        guard let close = body.firstIndex(of: quote) else { return nil }
        return String(body[..<close])
    }

    // MARK: - Inline

    // Inline scan: `code`, **bold**, *italic*/_italic_, ~~strike~~,
    // [text](url), ![alt](src) images, and [![alt](src)](href) linked badges.
    // Non-nested beyond that to keep it a single pass — good enough for prose
    // and READMEs.
    private static func inline(_ text: String, base: [NSAttributedString.Key: Any],
                               size: CGFloat, textColor: NSColor, mono: NSFont,
                               baseDir: String? = nil) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let chars = Array(text)
        var i = 0
        var run = ""
        let baseFont = (base[.font] as? NSFont) ?? NSFont.systemFont(ofSize: size)

        func flush() {
            if !run.isEmpty {
                result.append(NSAttributedString(string: run, attributes: base))
                run = ""
            }
        }
        func find(_ marker: [Character], from start: Int) -> Int? {
            var j = start
            while j + marker.count <= chars.count {
                if Array(chars[j..<j + marker.count]) == marker { return j }
                j += 1
            }
            return nil
        }

        while i < chars.count {
            let c = chars[i]
            if c == "`", let close = find(["`"], from: i + 1) {
                flush()
                var attrs = base
                attrs[.font] = mono
                attrs[.backgroundColor] = Theme.raised
                result.append(NSAttributedString(string: String(chars[(i + 1)..<close]), attributes: attrs))
                i = close + 1
                continue
            }
            if c == "*", i + 1 < chars.count, chars[i + 1] == "*", let close = find(["*", "*"], from: i + 2) {
                flush()
                var attrs = base
                attrs[.font] = bold(baseFont)
                result.append(NSAttributedString(string: String(chars[(i + 2)..<close]), attributes: attrs))
                i = close + 2
                continue
            }
            if (c == "*" || c == "_"), i + 1 < chars.count, chars[i + 1] != c, let close = find([c], from: i + 1) {
                flush()
                var attrs = base
                attrs[.font] = italic(baseFont)
                result.append(NSAttributedString(string: String(chars[(i + 1)..<close]), attributes: attrs))
                i = close + 1
                continue
            }
            if c == "~", i + 1 < chars.count, chars[i + 1] == "~", let close = find(["~", "~"], from: i + 2) {
                flush()
                var attrs = base
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                attrs[.foregroundColor] = Theme.textDim
                result.append(NSAttributedString(string: String(chars[(i + 2)..<close]), attributes: attrs))
                i = close + 2
                continue
            }
            // Inline image: ![alt](src). Local files land as the bitmap;
            // remote ones as a tagged placeholder the pane resolves.
            if c == "!", i + 1 < chars.count, chars[i + 1] == "[",
               let closeBracket = find(["]"], from: i + 2),
               closeBracket + 1 < chars.count, chars[closeBracket + 1] == "(",
               let closeParen = find([")"], from: closeBracket + 2) {
                let alt = String(chars[(i + 2)..<closeBracket])
                let src = imageSource(String(chars[(closeBracket + 2)..<closeParen]))
                if let fragment = imageFragment(alt: alt, src: src, baseDir: baseDir,
                                                size: size, maxWidth: nil, base: base) {
                    flush()
                    result.append(fragment)
                    i = closeParen + 1
                    continue
                }
            }
            // Link-wrapped image: [![alt](src)](href) — the badge pattern.
            if c == "[", i + 2 < chars.count, chars[i + 1] == "!", chars[i + 2] == "[",
               let altClose = find(["]"], from: i + 3),
               altClose + 1 < chars.count, chars[altClose + 1] == "(",
               let srcClose = find([")"], from: altClose + 2),
               srcClose + 2 < chars.count, chars[srcClose + 1] == "]", chars[srcClose + 2] == "(",
               let hrefClose = find([")"], from: srcClose + 3) {
                flush()
                let alt = String(chars[(i + 3)..<altClose])
                let src = imageSource(String(chars[(altClose + 2)..<srcClose]))
                var attrs = base
                attrs[.link] = String(chars[(srcClose + 3)..<hrefClose])
                if let fragment = imageFragment(alt: alt, src: src, baseDir: baseDir,
                                                size: size, maxWidth: nil, base: attrs) {
                    result.append(fragment)
                } else {
                    result.append(NSAttributedString(string: alt, attributes: attrs))
                }
                i = hrefClose + 1
                continue
            }
            if c == "[", let closeBracket = find(["]"], from: i + 1),
               closeBracket + 1 < chars.count, chars[closeBracket + 1] == "(",
               let closeParen = find([")"], from: closeBracket + 2) {
                flush()
                let label = String(chars[(i + 1)..<closeBracket])
                let url = String(chars[(closeBracket + 2)..<closeParen])
                var attrs = base
                attrs[.link] = url
                result.append(NSAttributedString(string: label, attributes: attrs))
                i = closeParen + 1
                continue
            }
            run.append(c)
            i += 1
        }
        flush()
        return result
    }

    // A fence's info string ("swift", "bash", "ts") → a highlighter language,
    // via CodeLanguage.detect on a synthetic filename plus a few names detect's
    // extension map doesn't cover.
    private static func fenceLanguage(_ info: String) -> CodeLanguage? {
        let name = info.lowercased()
        guard !name.isEmpty else { return nil }
        switch name {
        case "python": return .python
        case "shell", "console", "sh", "bash", "zsh": return .shell
        case "javascript", "typescript", "ts", "js": return .javascript
        case "golang": return .go
        case "objective-c", "objc", "c++", "cpp": return .c
        case "markdown": return .markdown
        default: return CodeLanguage.detect(path: "fence.\(name)")
        }
    }

    private static func bold(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }
    private static func italic(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    }
}
