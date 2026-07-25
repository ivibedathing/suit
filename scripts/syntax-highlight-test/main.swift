import Foundation

// Assertions for the viewer's syntax-highlighting core
// (swift/Sources/suit/SyntaxLanguages.swift — the language table plus the
// scanner, Foundation-only so it compiles without AppKit). Compiled and run by
// scripts/syntax-highlight-test.sh; same driver shape as the editor-ops /
// find-replace harnesses.
//
// The assertions are deliberately about *classification*, not span geometry:
// "the tag name is a keyword", "the attribute value is a string". That is the
// contract the viewer depends on, and it survives a rewrite of the scanner.

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok: \(message)")
    } else {
        print("  FAIL: \(message)")
        failures += 1
    }
}

// The kind assigned to the first occurrence of `needle` in `text`, or nil when
// no span starts exactly there.
func kind(of needle: String, in text: String, _ language: CodeLanguage) -> SyntaxTokenKind? {
    let ns = text as NSString
    let at = ns.range(of: needle)
    guard at.location != NSNotFound else { return nil }
    return SyntaxHighlighter.highlight(text: text, language: language)
        .first { $0.range.location == at.location }?.kind
}

// Whether some span covers `needle` entirely with the given kind — for tokens
// that live inside a larger span (a keyword inside a comment, say).
func covered(_ needle: String, in text: String, _ language: CodeLanguage, by kind: SyntaxTokenKind) -> Bool {
    let ns = text as NSString
    let at = ns.range(of: needle)
    guard at.location != NSNotFound else { return false }
    return SyntaxHighlighter.highlight(text: text, language: language).contains {
        $0.kind == kind && $0.range.location <= at.location
            && NSMaxRange($0.range) >= NSMaxRange(at)
    }
}

print("== detection ==")
do {
    check(CodeLanguage.detect(path: "/a/b/index.html") == .html, "html by extension")
    check(CodeLanguage.detect(path: "/a/app.vue") == .html, "vue reads as markup")
    check(CodeLanguage.detect(path: "/a/icon.svg") == .xml, "svg reads as xml")
    check(CodeLanguage.detect(path: "/a/main.css") == .css, "css by extension")
    check(CodeLanguage.detect(path: "/a/main.SCSS") == .scss, "detection is case-insensitive")
    check(CodeLanguage.detect(path: "/a/lib.rs") == .rust, "rust by extension")
    check(CodeLanguage.detect(path: "/a/Main.java") == .java, "java by extension")
    check(CodeLanguage.detect(path: "/a/q.sql") == .sql, "sql by extension")
    check(CodeLanguage.detect(path: "/a/Cargo.toml") == .toml, "toml by extension")
    check(CodeLanguage.detect(path: "/a/Gemfile") == .ruby, "bare Gemfile reads as ruby")
    check(CodeLanguage.detect(path: "/a/Dockerfile") == .dockerfile, "bare Dockerfile")
    check(CodeLanguage.detect(path: "/a/Dockerfile.dev") == .dockerfile, "Dockerfile.<suffix>")
    check(CodeLanguage.detect(path: "/a/Makefile") == .makefile, "bare Makefile")
    check(CodeLanguage.detect(path: "/a/.zshrc") == .shell, "dotfile by whole name")
    check(CodeLanguage.detect(path: "/a/notes.txt") == nil, "unknown extension stays plain")
    check(CodeLanguage.detect(path: "/a/README") == nil, "extensionless unknown stays plain")

    // The languages that shipped before the table existed must not have moved.
    check(CodeLanguage.detect(path: "a.swift") == .swift, "swift still detected")
    check(CodeLanguage.detect(path: "a.go") == .go, "go still detected")
    check(CodeLanguage.detect(path: "a.py") == .python, "python still detected")
    check(CodeLanguage.detect(path: "a.tsx") == .javascript, "typescript still detected")
    check(CodeLanguage.detect(path: "a.md") == .markdown, "markdown still detected")
    check(CodeLanguage.detect(path: "a.mm") == .c, "objc++ still detected")
}

print("")
print("== the generic code scanner ==")
do {
    check(kind(of: "func", in: "func f() {}", .swift) == .keyword, "swift keyword")
    check(kind(of: "\"hi\"", in: "let a = \"hi\"", .swift) == .string, "swift string")
    check(covered("secret", in: "// secret\n", .swift, by: .comment), "line comment swallows the line")
    check(kind(of: "fn", in: "fn main() {}", .rust) == .keyword, "rust keyword")
    check(kind(of: "#", in: "#[derive(Debug)]\n", .rust) == .attribute, "rust attribute")
    check(kind(of: "@Override", in: "@Override\nvoid f() {}", .java) == .attribute, "java annotation")
    check(kind(of: "$name", in: "<?php $name = 1;", .php) == .attribute, "php variable")
    check(kind(of: "SELECT", in: "SELECT * FROM t", .sql) == .keyword, "sql keyword, upper case")
    check(kind(of: "select", in: "select * from t", .sql) == .keyword, "sql keyword, lower case")
    check(covered("gone", in: "-- gone\nselect 1", .sql, by: .comment), "sql -- comment")
    check(covered("gone", in: "-- gone\nlocal x = 1", .lua, by: .comment), "lua -- comment")
    check(covered("gone", in: "--[[ gone\nstill gone ]] local x", .lua, by: .comment),
          "lua block comment wins over the line comment it starts with")
    check(covered("gone", in: "{- gone\nstill gone -} main", .haskell, by: .comment),
          "haskell block comment spans lines")
    check(kind(of: "FROM", in: "FROM alpine:3\n", .dockerfile) == .keyword, "dockerfile instruction")
    check(kind(of: "version", in: "version = \"1.0\"\n", .toml) == .key, "toml key before '='")
    check(kind(of: "name", in: "name: suit\n", .yaml) == .key, "yaml key before ':' still works")
    check(kind(of: "name", in: "name = 1\n", .yaml) != .key, "a yaml word before '=' is not a key")
    check(kind(of: "defmodule", in: "defmodule A do\nend", .elixir) == .keyword, "elixir keyword")
    check(kind(of: "$PSVersion", in: "$PSVersion\n", .powershell) == .attribute, "powershell variable")
}

print("")
print("== markup ==")
do {
    let page = "<!DOCTYPE html>\n<div class=\"a\" id=x>hi &amp;</div>\n<!-- note -->\n"
    check(covered("<!DOCTYPE html>", in: page, .html, by: .attribute), "doctype")
    check(kind(of: "<div", in: page, .html) == .keyword, "opening tag name")
    check(kind(of: "class", in: page, .html) == .attribute, "attribute name")
    check(kind(of: "\"a\"", in: page, .html) == .string, "quoted attribute value")
    check(kind(of: "x>", in: page, .html) == .string, "unquoted attribute value stops at '>'")
    check(kind(of: "&amp;", in: page, .html) == .number, "entity")
    check(kind(of: "</div", in: page, .html) == .keyword, "closing tag name")
    check(covered("note", in: page, .html, by: .comment), "html comment")
    check(kind(of: "hi", in: page, .html) == nil, "text between tags stays plain")

    let unterminated = "<p>before <!-- open forever"
    check(covered("open forever", in: unterminated, .html, by: .comment),
          "an unterminated comment runs to EOF instead of hanging")
    check(kind(of: "<", in: "a < b and c > d", .html) == nil, "a bare '<' in prose is not a tag")

    let xml = "<?xml version=\"1.0\"?>\n<node xlink:href=\"u\"/>\n"
    check(covered("<?xml", in: xml, .xml, by: .attribute), "xml declaration")
    check(kind(of: "xlink:href", in: xml, .xml) == .attribute, "namespaced attribute name")
    check(kind(of: "<node", in: xml, .xml) == .keyword, "self-closing tag")

    // Embedded script/style are the reason HTML highlighting is worth having.
    let embedded = "<script>\nconst x = 1; // c\n</script>\n<style>\n.a { color: red; }\n</style>\n"
    check(kind(of: "const", in: embedded, .html) == .keyword, "embedded <script> gets JS keywords")
    check(covered("// c", in: embedded, .html, by: .comment), "embedded JS comment")
    check(kind(of: "color", in: embedded, .html) == .key, "embedded <style> gets CSS properties")
    check(kind(of: "</script", in: embedded, .html) == .keyword, "the script closer is a tag again")
}

print("")
print("== style sheets ==")
do {
    let sheet = ".card, div { color: #ff0; margin: 12px 0; content: \"x\"; }\n/* note */\n#main { }\n"
    check(kind(of: ".card", in: sheet, .css) == .type, "class selector")
    check(kind(of: "div", in: sheet, .css) == .type, "element selector")
    check(kind(of: "color", in: sheet, .css) == .key, "property name")
    check(kind(of: "#ff0", in: sheet, .css) == .number, "hex color inside a block")
    check(kind(of: "12px", in: sheet, .css) == .number, "length with a unit")
    check(kind(of: "\"x\"", in: sheet, .css) == .string, "string value")
    check(covered("note", in: sheet, .css, by: .comment), "css block comment")
    check(kind(of: "#main", in: sheet, .css) == .type, "id selector outside a block")

    let at = "@media (min-width: 40rem) { .a { top: 0; } }\n"
    check(kind(of: "@media", in: at, .css) == .keyword, "at-rule")
    check(kind(of: "top", in: at, .css) == .key, "property inside a nested block")

    let scss = "$brand: red;\n// note\n.a { color: $brand; }\n"
    check(kind(of: "$brand", in: scss, .scss) == .attribute, "scss variable")
    check(covered("note", in: scss, .scss, by: .comment), "scss // comment")
    check(kind(of: "$brand", in: scss, .css) != .attribute, "plain css has no $ variables")

    check(SyntaxHighlighter.highlight(text: "a { }", language: .css).isEmpty == false, "css produces spans")
    // More closers than openers must not drive the depth counter negative.
    let unbalanced = "}}}} p { color: red; } }"
    check(kind(of: "color", in: unbalanced, .css) == .key,
          "unbalanced braces don't corrupt the selector/declaration context")
}

print("")
print("== limits ==")
do {
    check(SyntaxHighlighter.highlight(text: "", language: .swift).isEmpty, "empty text yields no spans")
    let huge = String(repeating: "a", count: SyntaxHighlighter.maxLength + 1)
    check(SyntaxHighlighter.highlight(text: huge, language: .swift).isEmpty, "oversized files bail out")
    // Every span must be inside the text, or the viewer's addAttribute throws.
    for (name, language) in [("html", CodeLanguage.html), ("css", .css), ("scss", .scss),
                             ("xml", .xml), ("rust", .rust), ("sql", .sql), ("lua", .lua)] {
        let text = "<a href=\"x\">/* $y */ 12px #z { k: v; } -- c\n\"s\n"
        let length = (text as NSString).length
        let bad = SyntaxHighlighter.highlight(text: text, language: language)
            .filter { $0.range.location < 0 || NSMaxRange($0.range) > length }
        check(bad.isEmpty, "\(name) spans stay inside the text on junk input")
    }
}

print("")
if failures == 0 {
    print("All syntax-highlight assertions passed.")
} else {
    print("\(failures) syntax-highlight assertion(s) FAILED.")
}
exit(failures == 0 ? 0 : 1)
