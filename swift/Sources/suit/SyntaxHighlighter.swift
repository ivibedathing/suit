import Cocoa

// Lightweight syntax highlighting for the file viewer. Per
// the roadmap's fallback note, this is a hand-rolled single-pass scanner, not
// tree-sitter: good-enough token classes (comments, strings, keywords, numbers,
// types, attributes) for the languages actually in use, swappable for
// tree-sitter later without touching the viewer (same SyntaxSpan output).

enum SyntaxTokenKind {
    case keyword
    case string
    case comment
    case number
    case type       // capitalized identifiers in C-like languages
    case attribute  // @attr / #directive / $var / markdown headings
    case key        // JSON/YAML keys, markdown inline code

    // A palette tuned for the app's dark terminal backgrounds. Foreground-only,
    // so the pane's translucency/background settings show through untouched.
    var color: NSColor {
        switch self {
        case .keyword: return NSColor(calibratedRed: 0.78, green: 0.47, blue: 0.87, alpha: 1)
        case .string: return NSColor(calibratedRed: 0.54, green: 0.79, blue: 0.49, alpha: 1)
        case .comment: return NSColor(calibratedWhite: 0.52, alpha: 1)
        case .number: return NSColor(calibratedRed: 0.90, green: 0.65, blue: 0.40, alpha: 1)
        case .type: return NSColor(calibratedRed: 0.42, green: 0.78, blue: 0.86, alpha: 1)
        case .attribute: return NSColor(calibratedRed: 0.86, green: 0.74, blue: 0.41, alpha: 1)
        case .key: return NSColor(calibratedRed: 0.45, green: 0.69, blue: 0.94, alpha: 1)
        }
    }
}

struct SyntaxSpan {
    let range: NSRange
    let kind: SyntaxTokenKind
}

enum CodeLanguage {
    case swift, go, javascript, python, shell, json, yaml, markdown, c

    static func detect(path: String) -> CodeLanguage? {
        let name = (path as NSString).lastPathComponent.lowercased()
        switch (name as NSString).pathExtension {
        case "swift": return .swift
        case "go": return .go
        case "js", "jsx", "ts", "tsx", "mjs", "cjs": return .javascript
        case "py": return .python
        case "sh", "bash", "zsh": return .shell
        case "json": return .json
        case "yaml", "yml": return .yaml
        case "md", "markdown": return .markdown
        case "c", "h", "m", "mm", "cpp", "hpp", "cc": return .c
        default:
            switch name {
            case "makefile", "dockerfile", ".zshrc", ".zprofile", ".bashrc", "build.sh": return .shell
            default: return nil
            }
        }
    }

    var keywords: Set<String> {
        switch self {
        case .swift:
            return ["func", "let", "var", "if", "else", "guard", "return", "class", "struct", "enum",
                    "protocol", "extension", "import", "for", "while", "in", "switch", "case", "default",
                    "break", "continue", "defer", "do", "try", "catch", "throw", "throws", "rethrows",
                    "init", "deinit", "self", "super", "nil", "true", "false", "static", "final",
                    "private", "fileprivate", "internal", "public", "open", "override", "weak", "unowned",
                    "lazy", "mutating", "where", "as", "is", "any", "some", "typealias", "associatedtype",
                    "inout", "indirect", "convenience", "required", "subscript", "get", "set", "didSet", "willSet"]
        case .go:
            return ["func", "var", "const", "type", "struct", "interface", "map", "chan", "if", "else",
                    "for", "range", "switch", "case", "default", "break", "continue", "return", "go",
                    "defer", "select", "package", "import", "fallthrough", "goto", "nil", "true", "false",
                    "iota", "make", "new", "len", "cap", "append", "copy", "delete", "panic", "recover",
                    "string", "int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16",
                    "uint32", "uint64", "float32", "float64", "bool", "byte", "rune", "error", "any"]
        case .javascript:
            return ["function", "const", "let", "var", "if", "else", "for", "while", "do", "switch",
                    "case", "default", "break", "continue", "return", "class", "extends", "super",
                    "new", "delete", "typeof", "instanceof", "in", "of", "try", "catch", "finally",
                    "throw", "async", "await", "yield", "import", "export", "from", "as", "this",
                    "null", "undefined", "true", "false", "static", "get", "set", "interface", "type",
                    "enum", "implements", "readonly", "public", "private", "protected", "declare", "namespace"]
        case .python:
            return ["def", "class", "if", "elif", "else", "for", "while", "break", "continue", "return",
                    "import", "from", "as", "try", "except", "finally", "raise", "with", "lambda",
                    "pass", "yield", "global", "nonlocal", "del", "assert", "async", "await", "in",
                    "is", "not", "and", "or", "None", "True", "False", "self", "match", "case"]
        case .shell:
            return ["if", "then", "elif", "else", "fi", "for", "while", "until", "do", "done", "case",
                    "esac", "function", "return", "break", "continue", "local", "export", "readonly",
                    "declare", "set", "unset", "shift", "exit", "trap", "source", "alias", "echo",
                    "printf", "read", "cd", "test", "in"]
        case .c:
            return ["if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue",
                    "return", "goto", "struct", "union", "enum", "typedef", "static", "extern", "const",
                    "volatile", "inline", "void", "char", "short", "int", "long", "float", "double",
                    "signed", "unsigned", "sizeof", "class", "public", "private", "protected", "virtual",
                    "override", "template", "typename", "namespace", "using", "new", "delete", "nullptr",
                    "true", "false", "NULL", "self", "id", "instancetype", "nil", "YES", "NO"]
        case .json:
            return ["true", "false", "null"]
        case .yaml:
            return ["true", "false", "null", "yes", "no", "on", "off"]
        case .markdown:
            return []
        }
    }

    var lineComment: String? {
        switch self {
        case .swift, .go, .javascript, .c: return "//"
        case .python, .shell, .yaml: return "#"
        case .json, .markdown: return nil
        }
    }

    var blockComment: (start: String, end: String)? {
        switch self {
        case .swift, .go, .javascript, .c: return ("/*", "*/")
        default: return nil
        }
    }

    // "..." blocks in Python/Swift that span lines (''' handled too for Python).
    var multilineStringDelimiters: [String] {
        switch self {
        case .swift: return ["\"\"\""]
        case .python: return ["\"\"\"", "'''"]
        case .javascript: return ["`"]
        default: return []
        }
    }

    var stringDelimiters: [Character] {
        switch self {
        case .swift, .go, .json: return ["\""]
        case .javascript, .python, .yaml, .shell: return ["\"", "'"]
        case .c: return ["\"", "'"]
        case .markdown: return []
        }
    }

    // @attribute (Swift/Python decorators), #directive (Swift), $var (shell).
    var attributePrefixes: [Character] {
        switch self {
        case .swift: return ["@", "#"]
        case .python: return ["@"]
        case .shell, .yaml: return ["$"]
        default: return []
        }
    }

    var highlightsCapitalizedTypes: Bool {
        switch self {
        case .swift, .go, .javascript, .c, .python: return true
        default: return false
        }
    }
}

enum SyntaxHighlighter {
    // Past this, highlighting stops paying for itself (and the viewer already
    // caps files at 8 MB) — callers get [] and show plain text.
    static let maxLength = 2 * 1024 * 1024

    // Carry-over state between lines.
    private enum LineState: Equatable {
        case none
        case blockComment
        case multilineString(String)
    }

    static func highlight(text: String, language: CodeLanguage) -> [SyntaxSpan] {
        let ns = text as NSString
        guard ns.length > 0, ns.length <= maxLength else { return [] }
        if language == .markdown {
            return highlightMarkdown(ns)
        }

        var spans: [SyntaxSpan] = []
        var state = LineState.none

        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            state = scanLine(ns, lineRange: lineRange, language: language, state: state, into: &spans)
        }
        return spans
    }

    // Scans one line, appending spans; returns the state the next line starts in.
    private static func scanLine(
        _ ns: NSString, lineRange: NSRange, language: CodeLanguage,
        state: LineState, into spans: inout [SyntaxSpan]
    ) -> LineState {
        var state = state
        var i = lineRange.location
        let end = NSMaxRange(lineRange)

        func char(_ index: Int) -> unichar { ns.character(at: index) }
        func matches(_ literal: String, at index: Int) -> Bool {
            let length = (literal as NSString).length
            guard index + length <= end else { return false }
            return ns.substring(with: NSRange(location: index, length: length)) == literal
        }

        while i < end {
            switch state {
            case .blockComment:
                guard let close = language.blockComment?.end else { state = .none; continue }
                let closeRange = ns.range(of: close, options: [], range: NSRange(location: i, length: end - i))
                if closeRange.location == NSNotFound {
                    spans.append(SyntaxSpan(range: NSRange(location: i, length: end - i), kind: .comment))
                    return .blockComment
                }
                let commentEnd = NSMaxRange(closeRange)
                spans.append(SyntaxSpan(range: NSRange(location: i, length: commentEnd - i), kind: .comment))
                i = commentEnd
                state = .none

            case .multilineString(let delimiter):
                let closeRange = ns.range(of: delimiter, options: [], range: NSRange(location: i, length: end - i))
                if closeRange.location == NSNotFound {
                    spans.append(SyntaxSpan(range: NSRange(location: i, length: end - i), kind: .string))
                    return state
                }
                let stringEnd = NSMaxRange(closeRange)
                spans.append(SyntaxSpan(range: NSRange(location: i, length: stringEnd - i), kind: .string))
                i = stringEnd
                state = .none

            case .none:
                let c = char(i)

                // Line comment to EOL.
                if let lineComment = language.lineComment, matches(lineComment, at: i) {
                    spans.append(SyntaxSpan(range: NSRange(location: i, length: end - i), kind: .comment))
                    return .none
                }
                // Block comment.
                if let block = language.blockComment, matches(block.start, at: i) {
                    i += (block.start as NSString).length
                    state = .blockComment
                    // Attribute the opener to the comment span produced above.
                    spans.append(SyntaxSpan(range: NSRange(location: i - (block.start as NSString).length, length: (block.start as NSString).length), kind: .comment))
                    continue
                }
                // Multiline string opener (checked before single-char delimiters
                // since """ starts with ").
                if let delimiter = language.multilineStringDelimiters.first(where: { matches($0, at: i) }) {
                    let open = (delimiter as NSString).length
                    let closeRange = ns.range(of: delimiter, options: [], range: NSRange(location: i + open, length: end - i - open))
                    if closeRange.location == NSNotFound {
                        spans.append(SyntaxSpan(range: NSRange(location: i, length: end - i), kind: .string))
                        return .multilineString(delimiter)
                    }
                    let stringEnd = NSMaxRange(closeRange)
                    spans.append(SyntaxSpan(range: NSRange(location: i, length: stringEnd - i), kind: .string))
                    i = stringEnd
                    continue
                }
                // Single-line string.
                if let scalar = Unicode.Scalar(c), language.stringDelimiters.contains(Character(scalar)) {
                    var j = i + 1
                    while j < end {
                        if char(j) == unichar(92) { // backslash escape
                            j += 2
                            continue
                        }
                        if char(j) == c { break }
                        j += 1
                    }
                    let stringEnd = min(end, j + 1)
                    spans.append(SyntaxSpan(range: NSRange(location: i, length: stringEnd - i), kind: .string))
                    i = stringEnd
                    continue
                }
                // Attribute / directive / shell variable.
                if let scalar = Unicode.Scalar(c), language.attributePrefixes.contains(Character(scalar)),
                   i + 1 < end, isIdentifierChar(char(i + 1)) {
                    var j = i + 1
                    while j < end, isIdentifierChar(char(j)) { j += 1 }
                    spans.append(SyntaxSpan(range: NSRange(location: i, length: j - i), kind: .attribute))
                    i = j
                    continue
                }
                // Number.
                if isDigit(c) {
                    var j = i + 1
                    while j < end, isNumberChar(char(j)) { j += 1 }
                    spans.append(SyntaxSpan(range: NSRange(location: i, length: j - i), kind: .number))
                    i = j
                    continue
                }
                // Identifier / keyword / type.
                if isIdentifierStart(c) {
                    var j = i + 1
                    while j < end, isIdentifierChar(char(j)) { j += 1 }
                    let word = ns.substring(with: NSRange(location: i, length: j - i))
                    if language.keywords.contains(word) {
                        spans.append(SyntaxSpan(range: NSRange(location: i, length: j - i), kind: .keyword))
                    } else if language.highlightsCapitalizedTypes, let first = word.unicodeScalars.first,
                              CharacterSet.uppercaseLetters.contains(first) {
                        spans.append(SyntaxSpan(range: NSRange(location: i, length: j - i), kind: .type))
                    } else if language == .yaml || language == .json {
                        // Bare word followed by ':' reads as a key.
                        var k = j
                        while k < end, char(k) == unichar(32) { k += 1 }
                        if k < end, char(k) == unichar(58) {
                            spans.append(SyntaxSpan(range: NSRange(location: i, length: j - i), kind: .key))
                        }
                    }
                    i = j
                    continue
                }
                i += 1
            }
        }
        return state
    }

    // Markdown never nests the way code does; simple per-line classification
    // plus a fenced-code state carried across lines.
    private static func highlightMarkdown(_ ns: NSString) -> [SyntaxSpan] {
        var spans: [SyntaxSpan] = []
        var inFence = false

        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byLines) { substring, lineRange, _, _ in
            guard let line = substring else { return }
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                spans.append(SyntaxSpan(range: lineRange, kind: .comment))
                inFence.toggle()
                return
            }
            if inFence {
                spans.append(SyntaxSpan(range: lineRange, kind: .key))
                return
            }
            if trimmed.hasPrefix("#") {
                spans.append(SyntaxSpan(range: lineRange, kind: .attribute))
                return
            }
            if trimmed.hasPrefix(">") {
                spans.append(SyntaxSpan(range: lineRange, kind: .comment))
                return
            }
            // Inline `code` spans.
            var searchStart = lineRange.location
            let lineEnd = NSMaxRange(lineRange)
            while searchStart < lineEnd {
                let open = ns.range(of: "`", options: [], range: NSRange(location: searchStart, length: lineEnd - searchStart))
                guard open.location != NSNotFound else { break }
                let close = ns.range(of: "`", options: [], range: NSRange(location: NSMaxRange(open), length: lineEnd - NSMaxRange(open)))
                guard close.location != NSNotFound else { break }
                spans.append(SyntaxSpan(range: NSRange(location: open.location, length: NSMaxRange(close) - open.location), kind: .key))
                searchStart = NSMaxRange(close)
            }
        }
        return spans
    }

    // MARK: - Character classes (UTF-16 code units)

    private static func isDigit(_ c: unichar) -> Bool {
        c >= 48 && c <= 57
    }

    private static func isNumberChar(_ c: unichar) -> Bool {
        isDigit(c) || c == 46 || c == 95 // . _
            || (c >= 97 && c <= 122) || (c >= 65 && c <= 90) // 0x1F, 1e9, 1_000
    }

    private static func isIdentifierStart(_ c: unichar) -> Bool {
        (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || c == 95
    }

    private static func isIdentifierChar(_ c: unichar) -> Bool {
        isIdentifierStart(c) || isDigit(c)
    }
}
