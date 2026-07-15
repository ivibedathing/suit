import Cocoa

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
                out.append(inline(content, base: attrs, size: size, textColor: textColor, mono: mono))
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

            // Block image on its own line (local files only).
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
            out.append(inline(parts.joined(separator: " "), base: attrs, size: size, textColor: textColor, mono: mono))
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

    // `![alt](src)` alone on a line, when src is a local file → the image
    // itself, scaled into the column. Remote/missing sources fall through to
    // the inline link rendering.
    private static func imageLine(_ trimmed: String, baseDir: String?, size: CGFloat) -> NSAttributedString? {
        guard trimmed.hasPrefix("!["), trimmed.hasSuffix(")"),
              let bracket = trimmed.range(of: "](") else { return nil }
        let rawSrc = String(trimmed[bracket.upperBound..<trimmed.index(before: trimmed.endIndex)])
            .trimmingCharacters(in: .whitespaces)
        let src = rawSrc.components(separatedBy: " ").first ?? rawSrc
        guard !src.isEmpty, !src.contains("://") else { return nil }
        let path = src.hasPrefix("/")
            ? src
            : ((baseDir ?? "") as NSString).appendingPathComponent(src)
        let standardized = (path as NSString).standardizingPath
        guard let image = NSImage(contentsOfFile: standardized), image.size.width > 0 else { return nil }

        let attachment = NSTextAttachment()
        attachment.image = image
        let maxWidth: CGFloat = 680
        var bounds = image.size
        if bounds.width > maxWidth {
            bounds = NSSize(width: maxWidth, height: bounds.height * maxWidth / bounds.width)
        }
        attachment.bounds = NSRect(origin: .zero, size: bounds)

        let para = NSMutableParagraphStyle()
        para.paragraphSpacingBefore = size * 0.4
        para.paragraphSpacing = size * 0.8
        let result = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
        result.append(NSAttributedString(string: "\n"))
        result.addAttributes(
            [.paragraphStyle: para],
            range: NSRange(location: 0, length: result.length)
        )
        return result
    }

    // MARK: - Inline

    // Inline scan: `code`, **bold**, *italic*/_italic_, ~~strike~~,
    // [text](url). Non-nested to keep it a single pass — good enough for prose
    // and READMEs.
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
            if c == "~", i + 1 < chars.count, chars[i + 1] == "~", let close = find(["~", "~"], from: i + 2) {
                flush()
                var attrs = base
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                attrs[.foregroundColor] = Theme.textDim
                result.append(NSAttributedString(string: String(chars[(i + 2)..<close]), attributes: attrs))
                i = close + 2
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
