import Foundation

// Standalone assertion driver for MarkdownHTML.swift (compiled by
// scripts/markdown-html-test.sh; the parser is Foundation-only so it links
// without AppKit). Covers the raw-HTML subset the markdown preview renders:
// the centered `<p align="center"><img></p>` header idiom, centered headings,
// `<a href><img></a>` badge rows, inline `<strong>`/`<em>`/`<br>`, and the
// fail-closed fallback for anything outside the whitelist.
//
// The README header is embedded as a literal fixture on purpose — reading the
// live README.md would make this harness fail whenever someone edits prose.
// Mirrors the roadmap-routing-test driver style.

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok: \(message)")
    } else {
        print("  FAIL: \(message)")
        failures += 1
    }
}

func parse(_ source: String) -> (block: MarkdownHTML.Block, lineCount: Int)? {
    MarkdownHTML.block(in: source.components(separatedBy: "\n"), at: 0)
}

// A copy of README.md's header as of the change that taught the renderer HTML.
let readmeHeader = """
<p align="center">
  <img src="design/app-icon.png" width="128" alt="Suit app icon">
</p>

<h1 align="center">Suit</h1>

<p align="center">
  <strong>Stop Using IDE Terminal.</strong><br>
  A native macOS terminal that's growing into a vibe-coding-first cockpit for codebase work.
</p>

<p align="center">
  <a href="https://github.com/ivibedathing/suit/actions/workflows/swift.yml"><img src="https://github.com/ivibedathing/suit/actions/workflows/swift.yml/badge.svg?branch=main" alt="CI status"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-000000?logo=apple&logoColor=white" alt="Platform: macOS 14+">
</p>
"""
let headerLines = readmeHeader.components(separatedBy: "\n")

// MARK: - The centered icon block

print("== centered image block ==")
if let (block, count) = MarkdownHTML.block(in: headerLines, at: 0) {
    check(count == 3, "the multi-line <p>…</p> block consumes all 3 of its lines")
    check(block.alignment == .center, "align=\"center\" is honored")
    check(block.kind == .paragraph, "<p> is a paragraph block")
    check(block.nodes.count == 1, "the block holds exactly the one image")
    if case .image(let alt, let src, let width, let href)? = block.nodes.first {
        check(src == "design/app-icon.png", "the src is parsed")
        check(width == 128, "width=\"128\" is parsed as a number")
        check(alt == "Suit app icon", "the alt text is parsed")
        check(href == nil, "an unwrapped image has no href")
    } else {
        check(false, "the node is an image")
    }
} else {
    check(false, "the README's centered icon block parses")
}

// MARK: - The centered heading

print("== centered heading ==")
if let (block, count) = MarkdownHTML.block(in: headerLines, at: 4) {
    check(count == 1, "a single-line <h1>…</h1> consumes one line")
    check(block.kind == .heading(1), "<h1> is a level-1 heading")
    check(block.alignment == .center, "the heading is centered")
    check(block.nodes == [.text("Suit", bold: false, italic: false, code: false, href: nil)],
          "the heading's text is unwrapped from its tags")
} else {
    check(false, "<h1 align=\"center\">Suit</h1> parses")
}

// MARK: - Inline emphasis and <br>

print("== inline <strong> and <br> ==")
if let (block, _) = MarkdownHTML.block(in: headerLines, at: 6) {
    check(block.alignment == .center, "the tagline block is centered")
    check(block.nodes.count == 3, "the tagline is bold text, a break, then prose")
    if case .text(let text, let bold, _, _, _)? = block.nodes.first {
        check(text == "Stop Using IDE Terminal.", "the <strong> text is unwrapped")
        check(bold, "…and marked bold")
    } else {
        check(false, "the first node is text")
    }
    check(block.nodes.count > 1 && block.nodes[1] == .lineBreak, "<br> becomes a line break node")
    if block.nodes.count > 2, case .text(let text, let bold, _, _, _) = block.nodes[2] {
        check(text.hasPrefix("A native macOS terminal"), "the prose after <br> joins the same block")
        check(!bold, "…and is not bold — </strong> closed")
        check(!text.contains("\n"), "the source's hard-wrapped newline collapses to a space")
    } else {
        check(false, "the third node is text")
    }
} else {
    check(false, "the tagline block parses")
}

// MARK: - The badge row

print("== badge row ==")
if let (block, _) = MarkdownHTML.block(in: headerLines, at: 11) {
    let images = block.nodes.compactMap { node -> (String, String?)? in
        if case .image(_, let src, _, let href) = node { return (src, href) }
        return nil
    }
    check(images.count == 2, "both badges in the row are images")
    check(images.first?.1 == "https://github.com/ivibedathing/suit/actions/workflows/swift.yml",
          "the <a href> wrapping the CI badge is carried onto the image")
    check(images.last?.1 == nil, "…and </a> closed, so the next badge is unlinked")
    check(images.last?.0.contains("img.shields.io") == true, "the shields.io badge keeps its query string")
} else {
    check(false, "the badge row parses")
}

// MARK: - Alignment variants

print("== alignment variants ==")
check(parse("<div align=\"center\">hi</div>")?.block.alignment == .center, "<div align=center> is a block")
check(parse("<p align='right'>hi</p>")?.block.alignment == .trailing, "single-quoted align=right")
check(parse("<p align=center>hi</p>")?.block.alignment == .center, "unquoted attribute values")
check(parse("<P ALIGN=\"CENTER\">hi</P>")?.block.alignment == .center, "tags and attributes are case-insensitive")
check(parse("<p>hi</p>")?.block.alignment == .leading, "no align attribute means leading")

// MARK: - Fail closed

print("== fail closed ==")
check(parse("<table><tr><td>x</td></tr></table>") == nil, "a non-whitelisted tag rejects the whole block")
check(parse("<details><summary>x</summary></details>") == nil,
      "<details> is not an inline block — MarkdownHTML.details owns it")
check(parse("<p>text <video src=\"x.mp4\"></video></p>") == nil,
      "one unknown tag rejects the block rather than partially rendering it")
check(parse("<p><div>nested</div></p>") == nil, "a nested block tag is past this parser's remit")
check(parse("<img>") == nil, "an <img> with no src is not renderable")
check(parse("Just prose.") == nil, "a non-HTML line does not open a block")
check(parse("<p align=\"center\">") == nil, "a block with no content yields nothing")

// MARK: - Regressions the old imageLine path used to cover

print("== bare and wrapped images ==")
if let (block, _) = parse("<img src=\"design/x.png\" alt=\"x\">") {
    check(block.alignment == .leading, "a bare <img> line still renders, unaligned")
    check(block.nodes.count == 1, "…as one image node")
} else {
    check(false, "a bare <img> line parses")
}
check(parse("<span><img src=\"x.png\"></span>")?.block.nodes.count == 1,
      "<span> is transparent, so a span-wrapped badge still renders")
if let (block, _) = parse("<p align=\"center\"><img src=\"a.png\"><img src=\"b.png\"></p>") {
    check(block.nodes.count == 2, "a single-line <p> with two images renders both")
    check(block.alignment == .center, "…centered — the old imageLine path dropped this")
} else {
    check(false, "the single-line <p><img><img></p> idiom parses")
}

// MARK: - Termination

print("== block termination ==")
let unclosed = ["<p align=\"center\">", "  <img src=\"x.png\">", "", "Next paragraph."]
if let (block, count) = MarkdownHTML.block(in: unclosed, at: 0) {
    check(count == 2, "an unclosed <p> ends at the blank line, not at EOF")
    check(block.nodes.count == 1, "…having collected its image")
} else {
    check(false, "an unclosed block still parses")
}
check(MarkdownHTML.block(in: ["<picture>", "</picture>"], at: 0) == nil,
      "<picture> is not mistaken for <p> — the tag-name boundary holds")

// MARK: - Entities

print("== entities ==")
if let (block, _) = parse("<p>a &amp; b &lt;c&gt; &quot;d&quot;</p>"),
   case .text(let text, _, _, _, _)? = block.nodes.first {
    check(text == "a & b <c> \"d\"", "the entities a README uses decode")
} else {
    check(false, "an entity-bearing block parses")
}
if let (block, _) = parse("<p>&amp;lt;</p>"), case .text(let text, _, _, _, _)? = block.nodes.first {
    check(text == "&lt;", "&amp; decodes last, so &amp;lt; is not double-decoded into <")
} else {
    check(false, "the double-encoding case parses")
}

// MARK: - <details> disclosures

print("== details ==")
// README.md's shortcuts section: a markdown body (headings + pipe tables) that
// has to flow back through the renderer's own block loop, and blank lines that
// must not terminate the block the way they do an inline HTML block.
let shortcuts = [
    "<details>",
    "<summary><strong>Show all shortcuts</strong></summary>",
    "",
    "### Tabs",
    "",
    "| Shortcut | Action |",
    "| --- | --- |",
    "| ⌘T | New tab |",
    "",
    "</details>",
    "",
    "After the disclosure.",
]
if let found = MarkdownHTML.details(in: shortcuts, at: 0) {
    check(found.lineCount == 10, "the block runs from <details> through </details>")
    check(!found.isOpen, "no `open` attribute means it starts collapsed")
    check(found.bodyStart == 2, "the body starts after the </summary> line")
    check(found.bodyEnd == 9, "…and ends at </details>, exclusive")
    check(found.summary == [.text("Show all shortcuts", bold: true, italic: false, code: false, href: nil)],
          "the summary's <strong> is parsed as inline nodes")
} else {
    check(false, "the README's shortcuts disclosure parses")
}

check(MarkdownHTML.details(in: ["<details open>", "<summary>s</summary>", "</details>"], at: 0)?.isOpen == true,
      "a bare `open` attribute starts it expanded")
check(MarkdownHTML.details(in: ["<details open=\"open\">", "<summary>s</summary>", "</details>"], at: 0)?.isOpen == true,
      "…as does open=\"open\"")
check(MarkdownHTML.details(in: ["<details class=\"opener\">", "<summary>s</summary>", "</details>"], at: 0)?.isOpen == false,
      "a word merely containing `open` is not the open flag")
// The `open` check reads the tag, not the line: summary prose is not a flag.
check(MarkdownHTML.details(in: ["<details><summary>Click to open the panel</summary>", "b", "</details>"], at: 0)?.isOpen == false,
      "the word `open` in same-line summary prose does not force it expanded")
check(MarkdownHTML.details(in: ["<details open><summary>Click to open it</summary>", "b", "</details>"], at: 0)?.isOpen == true,
      "…while a real `open` flag on that same shape still counts")

print("== details strands no content ==")
// The body is whole source lines, so text sharing a line with </summary> or
// </details> can't be carried. Rendering the block verbatim is the honest
// failure; dropping the prose silently is not.
check(MarkdownHTML.details(in: ["<details><summary>All on one line</summary>body</details>"], at: 0) == nil,
      "a single-line disclosure with body text fails closed rather than dropping it")
check(MarkdownHTML.details(in: ["<details>", "<summary>s</summary>stranded", "body", "</details>"], at: 0) == nil,
      "text after </summary> on its line fails closed")
check(MarkdownHTML.details(in: ["<details>", "<summary>s</summary>", "body</details>"], at: 0) == nil,
      "text before </details> on its line fails closed")
check(MarkdownHTML.details(in: ["<details><summary>s</summary>", "body", "</details>"], at: 0)?.bodyStart == 1,
      "…but a summary sharing only the <details> tag's line is fine")

print("== details fails closed ==")
check(MarkdownHTML.details(in: ["<details>", "<summary>s</summary>", "body"], at: 0) == nil,
      "an unclosed <details> yields nothing rather than swallowing the document")
check(MarkdownHTML.details(in: ["<details>", "body", "</details>"], at: 0) == nil,
      "a <details> with no <summary> is not a disclosure")
check(MarkdownHTML.details(in: ["<p>not a disclosure</p>"], at: 0) == nil,
      "a non-<details> line opens no disclosure")
let nested = ["<details>", "<summary>outer</summary>", "<details>", "<summary>in</summary>",
              "</details>", "</details>"]
if let found = MarkdownHTML.details(in: nested, at: 0) {
    check(found.lineCount == 6, "a nested <details> does not close its parent early")
    check(found.summary == [.text("outer", bold: false, italic: false, code: false, href: nil)],
          "…and the outer summary is the one parsed")
} else {
    check(false, "nested disclosures parse")
}

print(failures == 0 ? "\nAll markdown-html assertions passed." : "\n\(failures) assertion(s) failed.")
exit(failures == 0 ? 0 : 1)
