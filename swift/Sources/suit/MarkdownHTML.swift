import Foundation

// A deliberately bounded parser for the raw-HTML subset READMEs lean on: the
// `<p align="center"><img …></p>` header idiom, centered headings, badge rows
// of `<a href><img></a>`, and the `<strong>`/`<em>`/`<br>` inside them.
// CommonMark passes raw HTML through to the renderer and GitHub renders this
// subset, so a markdown preview that shows `<p align="center">` as literal
// text is simply wrong about the most-previewed file in any repo.
//
// The scope is a tag whitelist and the parser **fails closed**: a block
// holding any tag outside the list returns nil and the caller renders the
// source verbatim — today's behavior, never something worse. That is the
// mechanism keeping this from growing into an HTML engine one tag at a time.
// Unknown *attributes* are ignored rather than rejected: `<img loading=lazy>`
// should not drop a whole header back to literal tags.
//
// Foundation-only, and free of AppKit types on purpose — alignment is this
// file's own enum and widths are Double — so scripts/markdown-html-test can
// compile it standalone. MarkdownRenderer converts at the boundary.
enum MarkdownHTML {
    enum Alignment: Equatable {
        case leading, center, trailing
    }

    enum Kind: Equatable {
        case paragraph
        case heading(Int)
    }

    // Inline content of a block. `text` carries its own emphasis rather than
    // nesting, which keeps the renderer a flat loop; README-grade HTML never
    // nests deeper than `<a><img></a>` or `<strong>x</strong>`.
    enum Node: Equatable {
        case text(String, bold: Bool, italic: Bool, code: Bool, href: String?)
        case image(alt: String, src: String, width: Double?, href: String?)
        case lineBreak
    }

    struct Block: Equatable {
        var kind: Kind
        var alignment: Alignment
        var nodes: [Node]
    }

    // Tags that open a block. `div` earns its place: `<div align="center">` is
    // as common a README idiom as `<p>`. A bare `<img>`/`<a>` line opens an
    // implicit leading-aligned paragraph — that case used to be handled by
    // MarkdownRenderer.imageLine, and dropping it here would regress it.
    private static let blockTags: Set<String> = ["p", "div", "h1", "h2", "h3", "h4", "h5", "h6"]
    private static let inlineTags: Set<String> = ["img", "a", "br", "strong", "b", "em", "i", "code", "span"]
    private static let voidTags: Set<String> = ["img", "br"]

    /// Whether `line` could open an HTML block — a cheap prefilter so the
    /// renderer only pays for the full parse on lines that start a tag.
    ///
    /// The inline openers matter for continuity: MarkdownRenderer.imageLine
    /// used to pull `<img>` out of *any* `<`-prefixed line, so a line led by a
    /// bare `<img>`, an `<a>` badge, or a `<span>` wrapper has to keep
    /// rendering once this parser owns raw HTML.
    static func opensBlock(_ trimmed: String) -> Bool {
        guard trimmed.hasPrefix("<"), let tag = tagName(trimmed) else { return false }
        return blockTags.contains(tag) || ["img", "a", "span"].contains(tag)
    }

    /// Parse one HTML block beginning at `lines[start]`.
    /// Returns the block and how many source lines it consumed, or nil when the
    /// block is not the understood subset (caller renders it verbatim).
    static func block(in lines: [String], at start: Int) -> (block: Block, lineCount: Int)? {
        guard start < lines.count else { return nil }
        let first = lines[start].trimmingCharacters(in: .whitespaces)
        guard opensBlock(first), let opener = tagName(first) else { return nil }

        // Termination follows CommonMark's HTML-block rule: the matching close
        // tag, or a blank line, whichever comes first. README authors leave
        // `</p>` off constantly, and scanning to EOF on their behalf would
        // swallow the document.
        var collected: [String] = []
        var end = start
        var depth = 0
        var closed = false
        while end < lines.count {
            let line = lines[end]
            if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
            collected.append(line)
            end += 1
            if !voidTags.contains(opener) {
                depth += occurrences(of: "<\(opener)", in: line, requireTagBoundary: true)
                depth -= occurrences(of: "</\(opener)", in: line, requireTagBoundary: true)
                if depth <= 0 { closed = true; break }
            }
        }
        // An unclosed container that ran into a blank line is still parsed —
        // the tags we did see are unambiguous. Only the parse decides.
        _ = closed

        guard let block = parse(collected.joined(separator: "\n")) else { return nil }
        return (block, max(1, end - start))
    }

    // MARK: - Parsing

    // Walk the block as a token stream: text runs between tags, tags mutating a
    // small style state. Anything unexpected → nil, whole block.
    private static func parse(_ source: String) -> Block? {
        var kind: Kind = .paragraph
        var alignment: Alignment = .leading
        var sawBlockTag = false

        var nodes: [Node] = []
        var bold = 0, italic = 0, code = 0
        var href: String?
        var pending = ""

        func flushText() {
            var collapsed = collapseWhitespace(pending)
            pending = ""
            // A break swallows the indentation that follows it, the way HTML
            // means it — otherwise the source's own wrapping indents the line.
            if nodes.last == .lineBreak {
                collapsed = String(collapsed.drop { $0 == " " })
            }
            guard !collapsed.isEmpty else { return }
            // A text run that is only the space between two tags still matters
            // (badge rows separate `<img>`s by whitespace), but leading/trailing
            // block padding does not — the renderer trims at the edges.
            nodes.append(.text(decodeEntities(collapsed), bold: bold > 0, italic: italic > 0,
                               code: code > 0, href: href))
        }

        let chars = Array(source)
        var i = 0
        while i < chars.count {
            guard chars[i] == "<" else {
                pending.append(chars[i])
                i += 1
                continue
            }
            guard let close = indexOfTagEnd(chars, from: i) else { return nil }
            let raw = String(chars[i...close])
            guard let name = tagName(raw) else { return nil }
            let isClosing = raw.hasPrefix("</")

            if blockTags.contains(name) {
                // A block tag nested inside the block (e.g. `<div><p>`) is past
                // this parser's remit.
                if !isClosing {
                    if sawBlockTag { return nil }
                    sawBlockTag = true
                    alignment = parseAlignment(raw) ?? .leading
                    kind = headingLevel(name).map { Kind.heading($0) } ?? .paragraph
                }
                i = close + 1
                continue
            }
            guard inlineTags.contains(name) else { return nil }

            switch name {
            case "br":
                flushText()
                nodes.append(.lineBreak)
            case "img":
                flushText()
                guard let src = attribute("src", in: raw) else { return nil }
                nodes.append(.image(alt: attribute("alt", in: raw) ?? "", src: src,
                                    width: attribute("width", in: raw).flatMap(Double.init),
                                    href: href))
            case "a":
                flushText()
                href = isClosing ? nil : attribute("href", in: raw)
            case "strong", "b":
                flushText()
                bold += isClosing ? -1 : 1
            case "em", "i":
                flushText()
                italic += isClosing ? -1 : 1
            case "code":
                flushText()
                code += isClosing ? -1 : 1
            case "span":
                // Transparent: a styling hook we honor by ignoring, so a
                // `<span>`-wrapped badge still renders.
                flushText()
            default:
                return nil
            }
            i = close + 1
        }
        flushText()

        // Trim the whitespace-only runs the source's own indentation created at
        // the block's edges.
        while case .text(let t, _, _, _, _)? = nodes.first, t.trimmingCharacters(in: .whitespaces).isEmpty {
            nodes.removeFirst()
        }
        while case .text(let t, _, _, _, _)? = nodes.last, t.trimmingCharacters(in: .whitespaces).isEmpty {
            nodes.removeLast()
        }
        guard !nodes.isEmpty else { return nil }
        return Block(kind: kind, alignment: alignment, nodes: nodes)
    }

    // MARK: - Tag scanning

    // The `>` ending a tag, skipping any inside quoted attribute values.
    private static func indexOfTagEnd(_ chars: [Character], from start: Int) -> Int? {
        var i = start + 1
        var quote: Character?
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == ">" {
                return i
            }
            i += 1
        }
        return nil
    }

    /// The lowercased tag name of `<tag …>` or `</tag>`, nil if not a tag.
    static func tagName(_ raw: String) -> String? {
        var rest = Substring(raw)
        guard rest.first == "<" else { return nil }
        rest = rest.dropFirst()
        if rest.first == "/" { rest = rest.dropFirst() }
        let name = rest.prefix { $0.isLetter || $0.isNumber }
        return name.isEmpty ? nil : name.lowercased()
    }

    private static func headingLevel(_ tag: String) -> Int? {
        guard tag.count == 2, tag.hasPrefix("h"), let level = Int(tag.dropFirst()),
              (1...6).contains(level) else { return nil }
        return level
    }

    private static func parseAlignment(_ tag: String) -> Alignment? {
        switch attribute("align", in: tag)?.lowercased() {
        case "center": return .center
        case "right": return .trailing
        case "left": return .leading
        default: return nil
        }
    }

    /// An attribute's value from a tag: quoted or bare, case-insensitive name.
    /// Hoisted out of MarkdownRenderer so the one attribute parser is the
    /// tested one.
    static func attribute(_ name: String, in tag: String) -> String? {
        let lower = tag.lowercased()
        var search = lower.startIndex
        while let range = lower.range(of: "\(name)=", range: search..<lower.endIndex) {
            // Match on a word boundary so `width=` doesn't hit `data-width=`.
            let before = range.lowerBound == lower.startIndex
                ? " "
                : String(lower[lower.index(before: range.lowerBound)])
            guard before == " " || before == "\t" || before == "\n" else {
                search = range.upperBound
                continue
            }
            let offset = lower.distance(from: lower.startIndex, to: range.upperBound)
            let after = tag[tag.index(tag.startIndex, offsetBy: offset)...]
            guard let quote = after.first, quote == "\"" || quote == "'" else {
                let value = after.prefix { $0 != " " && $0 != ">" && $0 != "/" }
                return value.isEmpty ? nil : String(value)
            }
            let body = after.dropFirst()
            guard let close = body.firstIndex(of: quote) else { return nil }
            return String(body[..<close])
        }
        return nil
    }

    // Count `<tag`/`</tag` occurrences, requiring the next char to end the name
    // so `<p` doesn't match `<picture`.
    private static func occurrences(of needle: String, in line: String, requireTagBoundary: Bool) -> Int {
        let lower = line.lowercased()
        var count = 0
        var search = lower.startIndex
        while let range = lower.range(of: needle, range: search..<lower.endIndex) {
            search = range.upperBound
            guard requireTagBoundary else { count += 1; continue }
            if range.upperBound == lower.endIndex {
                count += 1
                continue
            }
            let next = lower[range.upperBound]
            if !next.isLetter && !next.isNumber { count += 1 }
        }
        return count
    }

    // MARK: - Text

    // Source newlines and indentation inside a block are insignificant, the way
    // HTML means them: any whitespace run collapses to one space.
    private static func collapseWhitespace(_ text: String) -> String {
        var out = ""
        var lastWasSpace = false
        for c in text {
            if c.isWhitespace {
                if !lastWasSpace { out.append(" ") }
                lastWasSpace = true
            } else {
                out.append(c)
                lastWasSpace = false
            }
        }
        return out
    }

    // Just the entities a README actually uses. Not a general table — a bigger
    // one would be scope creep with no caller.
    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = text
        for (entity, replacement) in [
            ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"),
            ("&apos;", "'"), ("&nbsp;", "\u{00A0}"), ("&mdash;", "—"), ("&ndash;", "–"),
        ] {
            out = out.replacingOccurrences(of: entity, with: replacement)
        }
        // Ampersand last, so `&amp;lt;` decodes to `&lt;` and not `<`.
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }
}
