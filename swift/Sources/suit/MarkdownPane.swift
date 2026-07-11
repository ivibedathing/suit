import Cocoa

// Markdown preview tab: renders `.md`/`.markdown` as
// formatted read-only text — headings, lists, fenced code (colored by
// SyntaxHighlighter), blockquotes, rules, and inline emphasis/code/links.
// A toggle flips rendered ↔ raw; raw is the plain highlighted source, the same
// surface a code file gets in the viewer. Deliberately read-only.

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
                source, baseFont: baseFont, textColor: baseTextColor
            )
        }
        textView.textStorage?.setAttributedString(attributed)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
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

// A compact line-based Markdown → NSAttributedString renderer. Not a full
// CommonMark implementation — headings, lists, fenced/inline code, blockquotes,
// rules, emphasis, and links, which covers READMEs and design notes. The raw
// mode reuses the viewer's SyntaxHighlighter, so the two modes share one look.
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

    static func render(_ text: String, baseFont: NSFont, textColor: NSColor) -> NSAttributedString {
        let size = baseFont.pointSize
        let body = NSFont.systemFont(ofSize: size)
        let mono = NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular)
        let out = NSMutableAttributedString()

        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = size * 0.5
        paragraph.lineSpacing = size * 0.15

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
                out.append(codeBlock(code.joined(separator: "\n"), info: info, font: mono, textColor: textColor))
                continue
            }

            // Horizontal rule.
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                let rule = NSMutableAttributedString(string: "\u{00A0}\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 4),
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: Theme.hairline,
                ])
                out.append(rule)
                i += 1
                continue
            }

            // ATX heading.
            if let (level, content) = heading(trimmed) {
                let scale: CGFloat = [1.7, 1.45, 1.25, 1.1, 1.0, 0.9][min(level - 1, 5)]
                let headingFont = NSFont.systemFont(ofSize: size * scale, weight: .bold)
                let para = NSMutableParagraphStyle()
                para.paragraphSpacingBefore = size * 0.6
                para.paragraphSpacing = size * 0.3
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: headingFont, .foregroundColor: textColor, .paragraphStyle: para,
                ]
                out.append(inline(content, base: attrs, size: size, textColor: textColor, mono: mono))
                out.append(NSAttributedString(string: "\n"))
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
                let para = NSMutableParagraphStyle()
                para.firstLineHeadIndent = 16
                para.headIndent = 16
                para.paragraphSpacing = size * 0.4
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: size), .foregroundColor: Theme.textDim,
                    .paragraphStyle: para,
                ]
                out.append(inline(quote.joined(separator: " "), base: attrs, size: size, textColor: Theme.textDim, mono: mono))
                out.append(NSAttributedString(string: "\n"))
                continue
            }

            // List item (bullet or ordered).
            if let (marker, content) = listItem(line) {
                let para = NSMutableParagraphStyle()
                para.firstLineHeadIndent = 18
                para.headIndent = 32
                para.paragraphSpacing = size * 0.1
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: body, .foregroundColor: textColor, .paragraphStyle: para,
                ]
                out.append(NSAttributedString(string: marker + " ", attributes: attrs))
                out.append(inline(content, base: attrs, size: size, textColor: textColor, mono: mono))
                out.append(NSAttributedString(string: "\n"))
                i += 1
                continue
            }

            // Blank line — paragraph separator.
            if trimmed.isEmpty {
                out.append(NSAttributedString(string: "\n"))
                i += 1
                continue
            }

            // Plain paragraph line.
            let attrs: [NSAttributedString.Key: Any] = [
                .font: body, .foregroundColor: textColor, .paragraphStyle: paragraph,
            ]
            out.append(inline(trimmed, base: attrs, size: size, textColor: textColor, mono: mono))
            out.append(NSAttributedString(string: "\n"))
            i += 1
        }
        return out
    }

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

    private static func listItem(_ line: String) -> (String, String)? {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        if let first = trimmed.first, "-*+".contains(first) {
            let rest = trimmed.dropFirst()
            if rest.first == " " {
                return ("•", String(rest.dropFirst()))
            }
        }
        // Ordered: digits then `. `.
        var digits = ""
        var rest = Substring(trimmed)
        while let c = rest.first, c.isNumber { digits.append(c); rest = rest.dropFirst() }
        if !digits.isEmpty, rest.first == ".", rest.dropFirst().first == " " {
            return (digits + ".", String(rest.dropFirst(2)))
        }
        return nil
    }

    private static func codeBlock(_ code: String, info: String, font: NSFont, textColor: NSColor) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.firstLineHeadIndent = 10
        para.headIndent = 10
        para.paragraphSpacingBefore = font.pointSize * 0.4
        para.paragraphSpacing = font.pointSize * 0.6
        let result = NSMutableAttributedString(string: code.isEmpty ? " " : code, attributes: [
            .font: font, .foregroundColor: textColor, .paragraphStyle: para,
            .backgroundColor: Theme.raised,
        ])
        if let language = fenceLanguage(info), (code as NSString).length <= SyntaxHighlighter.maxLength {
            for span in SyntaxHighlighter.highlight(text: code, language: language)
            where NSMaxRange(span.range) <= result.length {
                result.addAttribute(.foregroundColor, value: span.kind.color, range: span.range)
            }
        }
        result.append(NSAttributedString(string: "\n"))
        return result
    }

    // Inline scan: `code`, **bold**, *italic*/_italic_, [text](url). Non-nested
    // to keep it a single pass — good enough for prose and READMEs.
    private static func inline(_ text: String, base: [NSAttributedString.Key: Any],
                               size: CGFloat, textColor: NSColor, mono: NSFont) -> NSAttributedString {
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
