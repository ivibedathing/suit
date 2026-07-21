import Foundation

// The UI-free core of the viewer's syntax highlighting: the language table and
// the scanner that turns text into `SyntaxSpan`s. Foundation-only with no app
// deps — the EditorOps / RoadmapParser pattern — so
// scripts/syntax-highlight-test.sh compiles it standalone and asserts what each
// language classifies. SyntaxHighlighter.swift is the thin AppKit half: it maps
// a token kind to an NSColor and nothing else.
//
// Still a hand-rolled scanner rather than tree-sitter, and deliberately so: the
// output shape (`[SyntaxSpan]`) is the only thing the viewer knows about, so a
// real parser can replace this file later without touching a call site. What it
// buys is that a new language is *data* — one `CodeLanguage` value in the table
// below — not a new branch in five switch statements.
//
// Everything works in UTF-16 offsets (NSString's world), because that is what
// NSTextView consumes.

enum SyntaxTokenKind {
    case keyword
    case string
    case comment
    case number
    case type       // capitalized identifiers in C-like languages, markup selectors
    case attribute  // @attr / #directive / $var / markdown headings / HTML attributes
    case key        // JSON/YAML/TOML keys, CSS properties, markdown inline code
}

struct SyntaxSpan {
    let range: NSRange
    let kind: SyntaxTokenKind
}

// One language's traits. Two identically-configured languages are still
// distinct values (equality is by `id`) so callers can compare against the
// named statics below.
struct CodeLanguage: Equatable {
    // How the scanner reads the file. `code` is the generic C-ish tokenizer;
    // the other three are shapes it can't express — nested tags, selector vs.
    // declaration context, line-oriented prose.
    enum Flavor {
        case code, markup, style, markdown
    }

    let id: String
    var flavor: Flavor = .code
    var keywords: Set<String> = []
    var lineComment: String?
    var blockCommentStart: String?
    var blockCommentEnd: String?
    // Delimiters for strings that survive a newline (""" in Swift/Python, ` in JS).
    var multilineStringDelimiters: [String] = []
    var stringDelimiters: [Character] = ["\""]
    // @attribute (Swift/Python decorators), #directive, $var (shell/SCSS).
    var attributePrefixes: [Character] = []
    var highlightsCapitalizedTypes = false
    // Bare word followed by ':' reads as a key (JSON/YAML). TOML/INI use '='.
    var keysBeforeColon = false
    var keysBeforeEquals = false

    static func == (lhs: CodeLanguage, rhs: CodeLanguage) -> Bool { lhs.id == rhs.id }

    // MARK: - Constructors for the common shapes

    // `//` + `/* */`, both quote characters, capitalized words are types.
    private static func cLike(
        _ id: String, _ keywords: Set<String>,
        strings: [Character] = ["\"", "'"],
        multiline: [String] = [],
        attributes: [Character] = [],
        types: Bool = true
    ) -> CodeLanguage {
        CodeLanguage(
            id: id, keywords: keywords,
            lineComment: "//", blockCommentStart: "/*", blockCommentEnd: "*/",
            multilineStringDelimiters: multiline,
            stringDelimiters: strings, attributePrefixes: attributes,
            highlightsCapitalizedTypes: types
        )
    }

    // `#` to end of line, no block comment — the scripting/config shape.
    private static func hashLike(
        _ id: String, _ keywords: Set<String>,
        strings: [Character] = ["\"", "'"],
        attributes: [Character] = [],
        types: Bool = false
    ) -> CodeLanguage {
        CodeLanguage(
            id: id, keywords: keywords, lineComment: "#",
            stringDelimiters: strings, attributePrefixes: attributes,
            highlightsCapitalizedTypes: types
        )
    }
}

// MARK: - The language table

extension CodeLanguage {
    static let swift = cLike("swift", [
        "func", "let", "var", "if", "else", "guard", "return", "class", "struct", "enum",
        "protocol", "extension", "import", "for", "while", "in", "switch", "case", "default",
        "break", "continue", "defer", "do", "try", "catch", "throw", "throws", "rethrows",
        "init", "deinit", "self", "super", "nil", "true", "false", "static", "final",
        "private", "fileprivate", "internal", "public", "open", "override", "weak", "unowned",
        "lazy", "mutating", "where", "as", "is", "any", "some", "typealias", "associatedtype",
        "inout", "indirect", "convenience", "required", "subscript", "get", "set", "didSet", "willSet",
    ], strings: ["\""], multiline: ["\"\"\""], attributes: ["@", "#"])

    static let go = cLike("go", [
        "func", "var", "const", "type", "struct", "interface", "map", "chan", "if", "else",
        "for", "range", "switch", "case", "default", "break", "continue", "return", "go",
        "defer", "select", "package", "import", "fallthrough", "goto", "nil", "true", "false",
        "iota", "make", "new", "len", "cap", "append", "copy", "delete", "panic", "recover",
        "string", "int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16",
        "uint32", "uint64", "float32", "float64", "bool", "byte", "rune", "error", "any",
    ], strings: ["\"", "`"])

    static let javascript = cLike("javascript", [
        "function", "const", "let", "var", "if", "else", "for", "while", "do", "switch",
        "case", "default", "break", "continue", "return", "class", "extends", "super",
        "new", "delete", "typeof", "instanceof", "in", "of", "try", "catch", "finally",
        "throw", "async", "await", "yield", "import", "export", "from", "as", "this",
        "null", "undefined", "true", "false", "static", "get", "set", "interface", "type",
        "enum", "implements", "readonly", "public", "private", "protected", "declare", "namespace",
        "satisfies", "keyof", "infer", "abstract", "override",
    ], strings: ["\"", "'"], multiline: ["`"])

    static let python = CodeLanguage(
        id: "python", keywords: [
            "def", "class", "if", "elif", "else", "for", "while", "break", "continue", "return",
            "import", "from", "as", "try", "except", "finally", "raise", "with", "lambda",
            "pass", "yield", "global", "nonlocal", "del", "assert", "async", "await", "in",
            "is", "not", "and", "or", "None", "True", "False", "self", "match", "case",
        ],
        lineComment: "#",
        multilineStringDelimiters: ["\"\"\"", "'''"],
        stringDelimiters: ["\"", "'"], attributePrefixes: ["@"],
        highlightsCapitalizedTypes: true
    )

    static let shell = hashLike("shell", [
        "if", "then", "elif", "else", "fi", "for", "while", "until", "do", "done", "case",
        "esac", "function", "return", "break", "continue", "local", "export", "readonly",
        "declare", "set", "unset", "shift", "exit", "trap", "source", "alias", "echo",
        "printf", "read", "cd", "test", "in",
    ], attributes: ["$"])

    static let json = CodeLanguage(
        id: "json", keywords: ["true", "false", "null"],
        keysBeforeColon: true
    )

    static let yaml = hashLike("yaml", [
        "true", "false", "null", "yes", "no", "on", "off",
    ], attributes: ["$"]).keying(colon: true)

    static let markdown = CodeLanguage(id: "markdown", flavor: .markdown, stringDelimiters: [])

    static let c = cLike("c", [
        "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue",
        "return", "goto", "struct", "union", "enum", "typedef", "static", "extern", "const",
        "volatile", "inline", "void", "char", "short", "int", "long", "float", "double",
        "signed", "unsigned", "sizeof", "class", "public", "private", "protected", "virtual",
        "override", "template", "typename", "namespace", "using", "new", "delete", "nullptr",
        "true", "false", "NULL", "self", "id", "instancetype", "nil", "YES", "NO",
    ], attributes: ["#", "@"])

    // MARK: Web

    static let html = CodeLanguage(id: "html", flavor: .markup)
    static let xml = CodeLanguage(id: "xml", flavor: .markup)

    static let css = CodeLanguage(
        id: "css", flavor: .style,
        keywords: ["important", "inherit", "initial", "unset", "revert", "none", "auto",
                   "and", "not", "only", "from", "to", "var", "calc"],
        blockCommentStart: "/*", blockCommentEnd: "*/",
        stringDelimiters: ["\"", "'"]
    )

    // SCSS/Sass/Less: CSS plus `//` comments and `$`/`@` variables.
    static let scss = CodeLanguage(
        id: "scss", flavor: .style,
        keywords: css.keywords.union(["mixin", "include", "extend", "if", "else", "each",
                                      "for", "while", "function", "return", "use", "import"]),
        lineComment: "//", blockCommentStart: "/*", blockCommentEnd: "*/",
        stringDelimiters: ["\"", "'"], attributePrefixes: ["$"]
    )

    // MARK: Systems & application languages

    static let rust = cLike("rust", [
        "fn", "let", "mut", "const", "static", "if", "else", "match", "loop", "while", "for",
        "in", "break", "continue", "return", "struct", "enum", "trait", "impl", "type", "mod",
        "use", "pub", "crate", "super", "self", "Self", "as", "where", "dyn", "ref", "move",
        "unsafe", "extern", "async", "await", "yield", "true", "false", "bool", "char", "str",
        "u8", "u16", "u32", "u64", "u128", "usize", "i8", "i16", "i32", "i64", "i128", "isize",
        "f32", "f64", "Box", "Vec", "String", "Option", "Result", "Some", "None", "Ok", "Err",
    ], attributes: ["#"])

    static let java = cLike("java", [
        "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class",
        "const", "continue", "default", "do", "double", "else", "enum", "extends", "final",
        "finally", "float", "for", "goto", "if", "implements", "import", "instanceof", "int",
        "interface", "long", "native", "new", "package", "private", "protected", "public",
        "return", "short", "static", "strictfp", "super", "switch", "synchronized", "this",
        "throw", "throws", "transient", "try", "void", "volatile", "while", "var", "record",
        "sealed", "permits", "yield", "true", "false", "null",
    ], attributes: ["@"])

    static let kotlin = cLike("kotlin", [
        "fun", "val", "var", "if", "else", "when", "while", "for", "in", "is", "as", "return",
        "break", "continue", "class", "object", "interface", "data", "sealed", "enum", "annotation",
        "companion", "init", "constructor", "this", "super", "null", "true", "false", "package",
        "import", "typealias", "private", "protected", "public", "internal", "open", "abstract",
        "override", "final", "lateinit", "lazy", "by", "suspend", "inline", "reified", "operator",
        "infix", "vararg", "out", "try", "catch", "finally", "throw", "do", "it",
    ], attributes: ["@"])

    static let csharp = cLike("csharp", [
        "abstract", "as", "base", "bool", "break", "byte", "case", "catch", "char", "checked",
        "class", "const", "continue", "decimal", "default", "delegate", "do", "double", "else",
        "enum", "event", "explicit", "extern", "false", "finally", "fixed", "float", "for",
        "foreach", "goto", "if", "implicit", "in", "int", "interface", "internal", "is", "lock",
        "long", "namespace", "new", "null", "object", "operator", "out", "override", "params",
        "private", "protected", "public", "readonly", "ref", "return", "sbyte", "sealed", "short",
        "sizeof", "stackalloc", "static", "string", "struct", "switch", "this", "throw", "true",
        "try", "typeof", "uint", "ulong", "unchecked", "unsafe", "ushort", "using", "var",
        "virtual", "void", "volatile", "while", "async", "await", "record", "nameof", "when",
    ], attributes: ["#"])

    static let php = CodeLanguage(
        id: "php", keywords: [
            "abstract", "and", "array", "as", "break", "callable", "case", "catch", "class",
            "clone", "const", "continue", "declare", "default", "do", "echo", "else", "elseif",
            "empty", "enddeclare", "endfor", "endforeach", "endif", "endswitch", "endwhile",
            "enum", "extends", "final", "finally", "fn", "for", "foreach", "function", "global",
            "goto", "if", "implements", "include", "include_once", "instanceof", "insteadof",
            "interface", "isset", "list", "match", "namespace", "new", "or", "print", "private",
            "protected", "public", "readonly", "require", "require_once", "return", "static",
            "switch", "throw", "trait", "try", "unset", "use", "var", "while", "xor", "yield",
            "true", "false", "null", "this", "self", "parent",
        ],
        lineComment: "//", blockCommentStart: "/*", blockCommentEnd: "*/",
        stringDelimiters: ["\"", "'"], attributePrefixes: ["$", "#"],
        highlightsCapitalizedTypes: true
    )

    static let ruby = hashLike("ruby", [
        "alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "else",
        "elsif", "end", "ensure", "false", "for", "if", "in", "module", "next", "nil", "not",
        "or", "redo", "rescue", "retry", "return", "self", "super", "then", "true", "undef",
        "unless", "until", "when", "while", "yield", "require", "require_relative", "attr_accessor",
        "attr_reader", "attr_writer", "puts", "lambda", "proc", "new",
    ], attributes: ["@", "$"], types: true)

    static let lua = CodeLanguage(
        id: "lua", keywords: [
            "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto",
            "if", "in", "local", "nil", "not", "or", "repeat", "return", "then", "true",
            "until", "while", "self", "pairs", "ipairs", "require", "print",
        ],
        lineComment: "--", blockCommentStart: "--[[", blockCommentEnd: "]]",
        stringDelimiters: ["\"", "'"]
    )

    static let perl = hashLike("perl", [
        "my", "our", "local", "sub", "package", "use", "no", "require", "if", "elsif", "else",
        "unless", "while", "until", "for", "foreach", "do", "last", "next", "redo", "return",
        "wantarray", "defined", "undef", "ref", "bless", "die", "warn", "print", "printf",
        "push", "pop", "shift", "unshift", "splice", "keys", "values", "exists", "delete",
        "and", "or", "not", "eq", "ne", "lt", "gt", "le", "ge", "cmp", "qw", "eval",
    ], attributes: ["$", "@", "%"])

    static let r = hashLike("r", [
        "if", "else", "repeat", "while", "function", "for", "in", "next", "break", "TRUE",
        "FALSE", "NULL", "Inf", "NaN", "NA", "library", "require", "return", "invisible",
        "c", "list", "function", "print", "cat",
    ])

    static let scala = cLike("scala", [
        "abstract", "case", "catch", "class", "def", "do", "else", "extends", "false", "final",
        "finally", "for", "forSome", "if", "implicit", "import", "lazy", "match", "new", "null",
        "object", "override", "package", "private", "protected", "return", "sealed", "super",
        "this", "throw", "trait", "try", "true", "type", "val", "var", "while", "with", "yield",
        "given", "using", "enum", "export", "extension", "then",
    ], multiline: ["\"\"\""], attributes: ["@"])

    static let dart = cLike("dart", [
        "abstract", "as", "assert", "async", "await", "break", "case", "catch", "class", "const",
        "continue", "covariant", "default", "deferred", "do", "dynamic", "else", "enum", "export",
        "extends", "extension", "external", "factory", "false", "final", "finally", "for", "get",
        "hide", "if", "implements", "import", "in", "interface", "is", "late", "library", "mixin",
        "new", "null", "on", "operator", "part", "required", "rethrow", "return", "sealed", "set",
        "show", "static", "super", "switch", "sync", "this", "throw", "true", "try", "typedef",
        "var", "void", "while", "with", "yield",
    ], multiline: ["\"\"\"", "'''"], attributes: ["@"])

    static let elixir = hashLike("elixir", [
        "def", "defp", "defmodule", "defstruct", "defprotocol", "defimpl", "defmacro", "do",
        "end", "if", "unless", "else", "cond", "case", "when", "with", "for", "fn", "try",
        "catch", "rescue", "after", "raise", "throw", "import", "alias", "require", "use",
        "receive", "send", "spawn", "true", "false", "nil", "and", "or", "not", "in",
    ], attributes: ["@"], types: true)

    static let haskell = CodeLanguage(
        id: "haskell", keywords: [
            "module", "import", "where", "let", "in", "do", "case", "of", "if", "then", "else",
            "data", "newtype", "type", "class", "instance", "deriving", "qualified", "as",
            "hiding", "infix", "infixl", "infixr", "foreign", "default", "otherwise",
            "True", "False", "Just", "Nothing", "IO", "Maybe", "Either",
        ],
        lineComment: "--", blockCommentStart: "{-", blockCommentEnd: "-}",
        stringDelimiters: ["\"", "'"],
        highlightsCapitalizedTypes: true
    )

    static let zig = cLike("zig", [
        "fn", "var", "const", "comptime", "if", "else", "switch", "while", "for", "break",
        "continue", "return", "defer", "errdefer", "try", "catch", "struct", "enum", "union",
        "error", "pub", "export", "extern", "inline", "test", "orelse", "unreachable", "and",
        "or", "null", "true", "false", "undefined", "usingnamespace", "async", "await", "suspend",
        "u8", "u16", "u32", "u64", "usize", "i8", "i16", "i32", "i64", "isize", "f32", "f64",
        "bool", "void", "anytype", "type",
    ], attributes: ["@"])

    static let groovy = cLike("groovy", [
        "def", "class", "interface", "trait", "enum", "extends", "implements", "import",
        "package", "if", "else", "for", "while", "switch", "case", "default", "break",
        "continue", "return", "try", "catch", "finally", "throw", "throws", "new", "this",
        "super", "static", "final", "private", "protected", "public", "abstract", "synchronized",
        "null", "true", "false", "as", "in", "it", "assert", "task", "plugins", "dependencies",
    ], attributes: ["@"])

    static let powershell = hashLike("powershell", [
        "begin", "break", "catch", "class", "continue", "data", "do", "dynamicparam", "else",
        "elseif", "end", "enum", "exit", "filter", "finally", "for", "foreach", "from",
        "function", "hidden", "if", "in", "param", "process", "return", "switch", "throw",
        "trap", "try", "until", "using", "var", "while", "true", "false", "null",
    ], attributes: ["$"], types: true)

    // MARK: Data & config

    static let sql = CodeLanguage(
        id: "sql", keywords: [
            "select", "from", "where", "insert", "into", "values", "update", "set", "delete",
            "create", "alter", "drop", "table", "view", "index", "join", "inner", "left",
            "right", "full", "outer", "cross", "on", "group", "by", "order", "having", "limit",
            "offset", "union", "all", "distinct", "as", "and", "or", "not", "null", "is",
            "in", "between", "like", "exists", "case", "when", "then", "else", "end", "with",
            "primary", "foreign", "key", "references", "constraint", "default", "unique",
            "begin", "commit", "rollback", "transaction", "returning", "using", "cascade",
            "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",
            "CREATE", "ALTER", "DROP", "TABLE", "JOIN", "LEFT", "RIGHT", "INNER", "ON",
            "GROUP", "BY", "ORDER", "LIMIT", "AND", "OR", "NOT", "NULL", "AS", "DISTINCT",
        ],
        lineComment: "--", blockCommentStart: "/*", blockCommentEnd: "*/",
        stringDelimiters: ["'", "\""]
    )

    static let toml = hashLike("toml", ["true", "false"]).keying(equals: true)
    static let ini = hashLike("ini", ["true", "false", "yes", "no", "on", "off"]).keying(equals: true)

    static let protobuf = cLike("protobuf", [
        "syntax", "package", "import", "option", "message", "enum", "service", "rpc", "returns",
        "repeated", "optional", "required", "reserved", "oneof", "map", "extend", "public",
        "double", "float", "int32", "int64", "uint32", "uint64", "sint32", "sint64", "fixed32",
        "fixed64", "bool", "string", "bytes", "true", "false",
    ])

    static let graphql = hashLike("graphql", [
        "query", "mutation", "subscription", "fragment", "on", "type", "input", "interface",
        "union", "enum", "scalar", "schema", "directive", "extend", "implements", "true",
        "false", "null",
    ], attributes: ["@", "$"], types: true)

    // Terraform / HCL — `#` and `//` both comment, but only one fits the model;
    // `#` is the idiomatic one and `//` lines fall through as plain text.
    static let hcl = hashLike("hcl", [
        "resource", "variable", "output", "provider", "module", "data", "locals", "terraform",
        "for_each", "count", "depends_on", "true", "false", "null", "var", "local", "each",
        "if", "for", "in", "dynamic", "provisioner", "lifecycle",
    ]).keying(equals: true)

    static let makefile = hashLike("makefile", [
        "ifeq", "ifneq", "ifdef", "ifndef", "else", "endif", "include", "define", "endef",
        "export", "unexport", "override", "vpath", ".PHONY", "PHONY",
    ], attributes: ["$"])

    static let dockerfile = hashLike("dockerfile", [
        "FROM", "RUN", "CMD", "LABEL", "MAINTAINER", "EXPOSE", "ENV", "ADD", "COPY",
        "ENTRYPOINT", "VOLUME", "USER", "WORKDIR", "ARG", "ONBUILD", "STOPSIGNAL",
        "HEALTHCHECK", "SHELL", "AS", "as",
    ], attributes: ["$"])

    // Small helpers so the `keysBefore*` flags read as one word at the use site.
    private func keying(colon: Bool = false, equals: Bool = false) -> CodeLanguage {
        var copy = self
        copy.keysBeforeColon = colon
        copy.keysBeforeEquals = equals
        return copy
    }
}

// MARK: - Detection

extension CodeLanguage {
    // Extension → language. Lowercased keys; the caller lowercases the name.
    static let byExtension: [String: CodeLanguage] = [
        "swift": .swift,
        "go": .go,
        "js": .javascript, "jsx": .javascript, "ts": .javascript, "tsx": .javascript,
        "mjs": .javascript, "cjs": .javascript, "mts": .javascript, "cts": .javascript,
        "py": .python, "pyi": .python, "pyw": .python,
        "sh": .shell, "bash": .shell, "zsh": .shell, "fish": .shell, "ksh": .shell,
        "json": .json, "jsonc": .json, "json5": .json, "lock": .json,
        "yaml": .yaml, "yml": .yaml,
        "md": .markdown, "markdown": .markdown, "mdown": .markdown, "mdx": .markdown,
        "c": .c, "h": .c, "m": .c, "mm": .c, "cpp": .c, "hpp": .c, "cc": .c,
        "cxx": .c, "hh": .c, "hxx": .c, "ino": .c,

        "html": .html, "htm": .html, "xhtml": .html, "vue": .html, "svelte": .html,
        "ejs": .html, "hbs": .html, "handlebars": .html,
        "xml": .xml, "svg": .xml, "plist": .xml, "xib": .xml, "storyboard": .xml,
        "xsd": .xml, "xsl": .xml, "xslt": .xml, "rss": .xml, "atom": .xml, "resx": .xml,
        "css": .css,
        "scss": .scss, "sass": .scss, "less": .scss, "styl": .scss,

        "rs": .rust,
        "java": .java,
        "kt": .kotlin, "kts": .kotlin,
        "cs": .csharp, "csx": .csharp,
        "php": .php, "phtml": .php,
        "rb": .ruby, "rake": .ruby, "gemspec": .ruby, "ru": .ruby,
        "lua": .lua,
        "pl": .perl, "pm": .perl, "t": .perl,
        "r": .r, "rmd": .r,
        "scala": .scala, "sbt": .scala, "sc": .scala,
        "dart": .dart,
        "ex": .elixir, "exs": .elixir, "eex": .elixir, "heex": .elixir,
        "hs": .haskell, "lhs": .haskell,
        "zig": .zig,
        "groovy": .groovy, "gradle": .groovy, "jenkinsfile": .groovy,
        "ps1": .powershell, "psm1": .powershell, "psd1": .powershell,

        "sql": .sql, "psql": .sql, "mysql": .sql,
        "toml": .toml,
        "ini": .ini, "cfg": .ini, "conf": .ini, "properties": .ini, "editorconfig": .ini,
        "proto": .protobuf,
        "graphql": .graphql, "gql": .graphql,
        "tf": .hcl, "tfvars": .hcl, "hcl": .hcl, "nomad": .hcl,
        "mk": .makefile,
    ]

    // Whole filenames, for the extensionless files that carry real syntax.
    static let byFilename: [String: CodeLanguage] = [
        "makefile": .makefile, "gnumakefile": .makefile,
        "dockerfile": .dockerfile, "containerfile": .dockerfile,
        "gemfile": .ruby, "rakefile": .ruby, "podfile": .ruby, "fastfile": .ruby,
        "jenkinsfile": .groovy,
        "package.json": .json, "tsconfig.json": .json,
        ".zshrc": .shell, ".zprofile": .shell, ".zshenv": .shell,
        ".bashrc": .shell, ".bash_profile": .shell, ".profile": .shell,
        ".gitconfig": .ini, ".editorconfig": .ini, ".npmrc": .ini,
        "cargo.lock": .toml, "pipfile": .toml,
    ]

    static func detect(path: String) -> CodeLanguage? {
        let name = (path as NSString).lastPathComponent.lowercased()
        if let byName = byFilename[name] { return byName }
        // `Dockerfile.dev`, `Makefile.local` — the base name still decides.
        if name.hasPrefix("dockerfile.") { return .dockerfile }
        if name.hasPrefix("makefile.") { return .makefile }
        let ext = (name as NSString).pathExtension
        if let byExt = byExtension[ext] { return byExt }
        // A dotfile like `.zshrc` has no path extension on some inputs and the
        // whole name on others; both routes are covered above, so give up here.
        return nil
    }
}

// MARK: - The scanner

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
        switch language.flavor {
        case .markdown: return highlightMarkdown(ns)
        case .markup: return highlightMarkup(ns, offset: 0)
        case .style: return highlightStyle(ns, language: language, offset: 0)
        case .code: break
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
                guard let close = language.blockCommentEnd else { state = .none; continue }
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

                // Block comment before line comment: Lua's `--[[` starts with
                // its own line-comment token, and Haskell's `{-` likewise wins
                // over nothing. Whichever is longer at this position is right.
                if let start = language.blockCommentStart, matches(start, at: i) {
                    let openLength = (start as NSString).length
                    spans.append(SyntaxSpan(range: NSRange(location: i, length: openLength), kind: .comment))
                    i += openLength
                    state = .blockComment
                    continue
                }
                // Line comment to EOL.
                if let lineComment = language.lineComment, matches(lineComment, at: i) {
                    spans.append(SyntaxSpan(range: NSRange(location: i, length: end - i), kind: .comment))
                    return .none
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
                // Attribute / directive / shell variable. A '[' after the prefix
                // is Rust's `#[derive(…)]` and Swift's `@available`-adjacent
                // forms — the bracket belongs to the attribute, not the code.
                if let scalar = Unicode.Scalar(c), language.attributePrefixes.contains(Character(scalar)),
                   i + 1 < end, isIdentifierChar(char(i + 1)) || char(i + 1) == unichar(91) {
                    let nameStart = char(i + 1) == unichar(91) ? i + 2 : i + 1
                    var j = nameStart
                    while j < end, isIdentifierChar(char(j)) { j += 1 }
                    guard j > nameStart else { i += 1; continue }
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
                    } else if language.keysBeforeColon || language.keysBeforeEquals {
                        // Bare word followed by ':' (YAML/JSON) or '=' (TOML/INI)
                        // reads as a key.
                        var k = j
                        while k < end, char(k) == unichar(32) || char(k) == unichar(9) { k += 1 }
                        let separator: unichar = language.keysBeforeColon ? 58 : 61 // ':' / '='
                        if k < end, char(k) == separator {
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

    // MARK: - Markup (HTML / XML / SVG / Vue / Svelte)

    // Tags nest and attributes wrap across lines, so this is a whole-text pass
    // rather than the line-state machine above. `<script>` / `<style>` bodies
    // are handed to the JS and CSS scanners and their spans shifted into place —
    // an HTML file with an unhighlighted script block is most of a real page.
    private static func highlightMarkup(_ ns: NSString, offset: Int) -> [SyntaxSpan] {
        var spans: [SyntaxSpan] = []
        let length = ns.length
        var i = 0

        func matches(_ literal: String, at index: Int) -> Bool {
            let count = (literal as NSString).length
            guard index + count <= length else { return false }
            return ns.substring(with: NSRange(location: index, length: count)) == literal
        }
        func span(_ location: Int, _ count: Int, _ kind: SyntaxTokenKind) {
            guard count > 0 else { return }
            spans.append(SyntaxSpan(range: NSRange(location: location + offset, length: count), kind: kind))
        }

        while i < length {
            let c = ns.character(at: i)

            // <!-- comment -->, unterminated runs to EOF.
            if matches("<!--", at: i) {
                let close = ns.range(of: "-->", options: [], range: NSRange(location: i, length: length - i))
                let stop = close.location == NSNotFound ? length : NSMaxRange(close)
                span(i, stop - i, .comment)
                i = stop
                continue
            }
            // <!DOCTYPE …>, <![CDATA[…]]>, <?xml … ?>
            if matches("<!", at: i) || matches("<?", at: i) {
                var j = i + 2
                while j < length, ns.character(at: j) != unichar(62) { j += 1 } // '>'
                let stop = min(length, j + 1)
                span(i, stop - i, .attribute)
                i = stop
                continue
            }
            if c == unichar(60) { // '<'
                var j = i + 1
                let isClosing = j < length && ns.character(at: j) == unichar(47) // '/'
                if isClosing { j += 1 }
                let nameStart = j
                while j < length, isTagNameChar(ns.character(at: j)) { j += 1 }
                guard j > nameStart else { // a bare '<' in prose
                    i += 1
                    continue
                }
                let name = ns.substring(with: NSRange(location: nameStart, length: j - nameStart)).lowercased()
                span(i, j - i, .keyword) // '<' / '</' plus the tag name

                // Attributes up to the closing '>'.
                var selfClosing = false
                while j < length {
                    let a = ns.character(at: j)
                    if a == unichar(62) { j += 1; break } // '>'
                    if a == unichar(47), j + 1 < length, ns.character(at: j + 1) == unichar(62) { // '/>'
                        selfClosing = true
                        j += 2
                        break
                    }
                    if isTagNameChar(a) {
                        let attrStart = j
                        while j < length, isTagNameChar(ns.character(at: j)) { j += 1 }
                        span(attrStart, j - attrStart, .attribute)
                        // = value
                        var k = j
                        while k < length, isSpace(ns.character(at: k)) { k += 1 }
                        guard k < length, ns.character(at: k) == unichar(61) else { continue } // '='
                        k += 1
                        while k < length, isSpace(ns.character(at: k)) { k += 1 }
                        guard k < length else { j = k; continue }
                        let quote = ns.character(at: k)
                        if quote == unichar(34) || quote == unichar(39) { // " '
                            var v = k + 1
                            while v < length, ns.character(at: v) != quote { v += 1 }
                            let stop = min(length, v + 1)
                            span(k, stop - k, .string)
                            j = stop
                        } else {
                            var v = k
                            while v < length, !isSpace(ns.character(at: v)),
                                  ns.character(at: v) != unichar(62) { v += 1 }
                            span(k, v - k, .string)
                            j = v
                        }
                        continue
                    }
                    j += 1
                }
                i = j

                // Embedded JS / CSS.
                if !isClosing, !selfClosing, name == "script" || name == "style" {
                    let closer = "</\(name)"
                    let close = ns.range(of: closer, options: [.caseInsensitive], range: NSRange(location: i, length: length - i))
                    let bodyEnd = close.location == NSNotFound ? length : close.location
                    if bodyEnd > i {
                        let body = ns.substring(with: NSRange(location: i, length: bodyEnd - i)) as NSString
                        let inner = name == "script"
                            ? highlight(text: body as String, language: .javascript)
                            : highlightStyle(body, language: .css, offset: 0)
                        for s in inner {
                            spans.append(SyntaxSpan(
                                range: NSRange(location: s.range.location + i + offset, length: s.range.length),
                                kind: s.kind
                            ))
                        }
                    }
                    i = bodyEnd
                }
                continue
            }
            // &entity;
            if c == unichar(38) { // '&'
                var j = i + 1
                if j < length, ns.character(at: j) == unichar(35) { j += 1 } // '#'
                let digitsStart = j
                while j < length, j - digitsStart < 8, isIdentifierChar(ns.character(at: j)) { j += 1 }
                if j > digitsStart, j < length, ns.character(at: j) == unichar(59) { // ';'
                    span(i, j + 1 - i, .number)
                    i = j + 1
                    continue
                }
            }
            i += 1
        }
        return spans
    }

    // MARK: - Style sheets (CSS / SCSS / Sass / Less)

    // CSS needs to know whether it is reading a selector or a declaration —
    // `color` before a `{` is an element selector, after it is a property — so
    // the pass tracks brace depth rather than working line by line.
    private static func highlightStyle(_ ns: NSString, language: CodeLanguage, offset: Int) -> [SyntaxSpan] {
        var spans: [SyntaxSpan] = []
        let length = ns.length
        var i = 0
        var depth = 0

        func matches(_ literal: String, at index: Int) -> Bool {
            let count = (literal as NSString).length
            guard index + count <= length else { return false }
            return ns.substring(with: NSRange(location: index, length: count)) == literal
        }
        func span(_ location: Int, _ count: Int, _ kind: SyntaxTokenKind) {
            guard count > 0 else { return }
            spans.append(SyntaxSpan(range: NSRange(location: location + offset, length: count), kind: kind))
        }

        while i < length {
            let c = ns.character(at: i)

            if matches("/*", at: i) {
                let close = ns.range(of: "*/", options: [], range: NSRange(location: i, length: length - i))
                let stop = close.location == NSNotFound ? length : NSMaxRange(close)
                span(i, stop - i, .comment)
                i = stop
                continue
            }
            if let lineComment = language.lineComment, matches(lineComment, at: i) {
                var j = i
                while j < length, ns.character(at: j) != unichar(10) { j += 1 } // '\n'
                span(i, j - i, .comment)
                i = j
                continue
            }
            if c == unichar(34) || c == unichar(39) { // " '
                var j = i + 1
                while j < length, ns.character(at: j) != c {
                    if ns.character(at: j) == unichar(92) { j += 1 } // escape
                    j += 1
                }
                let stop = min(length, j + 1)
                span(i, stop - i, .string)
                i = stop
                continue
            }
            if c == unichar(123) { depth += 1; i += 1; continue } // '{'
            if c == unichar(125) { depth = max(0, depth - 1); i += 1; continue } // '}'

            // Every `@word` in a style sheet is an at-rule (@media, @mixin,
            // @import, @keyframes…), so the keyword list doesn't gate it — a
            // fixed list would go stale with every CSS spec revision. `$word`
            // is an SCSS/Less variable.
            if c == unichar(64) || (c == unichar(36) && language.attributePrefixes.contains("$")) {
                var j = i + 1
                while j < length, isIdentifierChar(ns.character(at: j)) || ns.character(at: j) == unichar(45) { j += 1 }
                if j > i + 1 {
                    span(i, j - i, c == unichar(64) ? .keyword : .attribute)
                    i = j
                    continue
                }
            }
            // #hex color inside a block, #id selector outside one.
            if c == unichar(35) { // '#'
                var j = i + 1
                while j < length, isIdentifierChar(ns.character(at: j)) || ns.character(at: j) == unichar(45) { j += 1 }
                if j > i + 1 {
                    span(i, j - i, depth > 0 ? .number : .type)
                    i = j
                    continue
                }
            }
            // .class selector.
            if c == unichar(46), depth == 0, i + 1 < length, isIdentifierStart(ns.character(at: i + 1)) {
                var j = i + 1
                while j < length, isIdentifierChar(ns.character(at: j)) || ns.character(at: j) == unichar(45) { j += 1 }
                span(i, j - i, .type)
                i = j
                continue
            }
            // 12px, 1.5rem, 50%.
            if isDigit(c) || (c == unichar(46) && i + 1 < length && isDigit(ns.character(at: i + 1))) {
                var j = i + 1
                while j < length, isNumberChar(ns.character(at: j)) || ns.character(at: j) == unichar(37) { j += 1 }
                span(i, j - i, .number)
                i = j
                continue
            }
            if isIdentifierStart(c) || c == unichar(45) { // '-' opens --custom-property
                var j = i
                while j < length, isIdentifierChar(ns.character(at: j)) || ns.character(at: j) == unichar(45) { j += 1 }
                guard j > i else { i += 1; continue }
                let word = ns.substring(with: NSRange(location: i, length: j - i))
                if language.keywords.contains(word.lowercased()) {
                    span(i, j - i, .keyword)
                } else if depth > 0 {
                    // A word followed by ':' is a property; anything else is a value.
                    var k = j
                    while k < length, isSpace(ns.character(at: k)) { k += 1 }
                    if k < length, ns.character(at: k) == unichar(58) { span(i, j - i, .key) } // ':'
                } else {
                    span(i, j - i, .type) // element / at-rule condition in a selector
                }
                i = j
                continue
            }
            i += 1
        }
        return spans
    }

    // MARK: - Markdown

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

    private static func isSpace(_ c: unichar) -> Bool {
        c == 32 || c == 9 || c == 10 || c == 13
    }

    // Tag and attribute names: `xlink:href`, `data-id`, `v-on:click`, `x.y`.
    private static func isTagNameChar(_ c: unichar) -> Bool {
        isIdentifierChar(c) || c == 45 || c == 58 || c == 46 // - : .
    }
}
