import Foundation

// Standalone assertion driver for the symbol-index core (ROADMAP Phase 33),
// compiled against swift/Sources/suit/SymbolIndex.swift (Foundation-only) by
// scripts/symbol-index-test.sh. Mirrors the RoadmapParser / FeedbackRouting
// standalone-test pattern: no app, no UI — just the pure ctags-output parser,
// the identifier extractor, the go-to-def outcome / header-note / word-search
// logic, and an end-to-end runCtags round-trip against a fake universal-ctags.

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok: \(message)")
    } else {
        print("  FAIL: \(message)")
        failures += 1
    }
}

// MARK: - parseTags (JSON tag lines → symbols)

print("== parseTags ==")
let singleJSON = #"""
{"_type":"tag","name":"parseTags","path":"swift/Sources/suit/SymbolIndex.swift","pattern":"/^func parseTags/","line":210,"kind":"function"}
"""#
let single = SymbolIndex.parseTags(singleJSON)
check(single.count == 1, "one tag parsed")
check(single.first == Symbol(name: "parseTags",
                             relativePath: "swift/Sources/suit/SymbolIndex.swift",
                             line: 210, kind: "function"),
      "single definition lands on the right file:line")

// Multi-definition: same name, two sites (an overload / shadow).
let multiJSON = """
{"_type":"tag","name":"load","path":"a.swift","line":12,"kind":"method"}
{"_type":"tag","name":"load","path":"b.swift","line":40,"kind":"method"}
{"_type":"ptag","name":"!_TAG_PROGRAM","path":"Universal Ctags"}
not json at all
{"_type":"tag","name":"other","path":"c.swift","line":3,"kind":"function"}
"""
let multi = SymbolIndex.index(SymbolIndex.parseTags(multiJSON))
check(multi["load"]?.count == 2, "two definitions for an overloaded name")
check(multi["load"]?.map { $0.line } == [12, 40], "both definition lines, in file order")
check(multi["load"]?.map { $0.relativePath } == ["a.swift", "b.swift"], "both definition files")
check(multi["other"]?.count == 1, "unrelated name unaffected")
check(multi["!_TAG_PROGRAM"] == nil, "pseudo-tags (ptag) skipped")
check(SymbolIndex.parseTags("").isEmpty, "empty output → no symbols")

// MARK: - gotoOutcome (0 / 1 / many)

print("== gotoOutcome ==")
let a = Symbol(name: "x", relativePath: "a.swift", line: 1, kind: "")
let b = Symbol(name: "x", relativePath: "b.swift", line: 2, kind: "")
check(SymbolNavigation.gotoOutcome(for: []) == .none, "no definitions → none (rg fallback)")
check(SymbolNavigation.gotoOutcome(for: [a]) == .jump(a), "one definition → jump")
check(SymbolNavigation.gotoOutcome(for: [a, b]) == .choose([a, b]), "several definitions → picker")

// MARK: - headerNote

print("== headerNote ==")
check(SymbolNavigation.headerNote(symbol: "Foo", ctagsAvailable: true) == "References to “Foo”",
      "ctags-backed header names the symbol")
check(SymbolNavigation.headerNote(symbol: "Foo", ctagsAvailable: false).contains("ctags unavailable"),
      "missing ctags → header note calls out the rg text-match fallback")

// MARK: - wordSearchPattern

print("== wordSearchPattern ==")
check(SymbolNavigation.wordSearchPattern(for: "fooBar_2") == #"\bfooBar_2\b"#,
      "identifier → whole-word regex")
check(!SymbolNavigation.wordSearchPattern(for: "a.b(c)").contains(#"\b"#),
      "non-identifier selection → escaped, unbounded (no bad-regex error)")

// MARK: - identifier extraction

print("== SymbolLookup.identifier ==")
let line = "  let result = parseTags(input)"
// Offsets: "  let result = parseTags(input)"
//           0123456789...
check(SymbolLookup.identifier(in: line, atUTF16Offset: 7) == "result", "caret inside a word")
check(SymbolLookup.identifier(in: line, atUTF16Offset: 6) == "result", "caret at word start")
check(SymbolLookup.identifier(in: line, atUTF16Offset: 12) == "result", "caret at word end resolves the abutting word")
check(SymbolLookup.identifier(in: line, atUTF16Offset: 14) == nil, "caret on whitespace between non-idents → nil")
check(SymbolLookup.identifier(in: line, atUTF16Offset: 16) == "parseTags", "caret at a later word")
check(SymbolLookup.identifier(in: "n1_ok", atUTF16Offset: 0) == "n1_ok", "digits and underscores are identifier chars")
check(SymbolLookup.identifier(in: "", atUTF16Offset: 0) == nil, "empty line → nil")

// MARK: - resolveCtagsExecutable (env override)

print("== resolveCtagsExecutable ==")
let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("suit-symbol-test-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

// A fake universal-ctags: reads the file list on stdin, emits one JSON tag per
// input file plus a shared "commonSymbol" so multi-def is exercised end-to-end.
let fakeCtags = tmp.appendingPathComponent("fake-ctags.sh")
let fakeScript = """
#!/bin/bash
# Ignore ctags' args; read the newline-separated file list on stdin.
while IFS= read -r f; do
  [ -z "$f" ] && continue
  printf '{"_type":"tag","name":"sym_%s","path":"%s","line":7,"kind":"function"}\\n' "$(basename "$f" .swift)" "$f"
  printf '{"_type":"tag","name":"commonSymbol","path":"%s","line":3,"kind":"variable"}\\n' "$f"
done
"""
try? fakeScript.write(to: fakeCtags, atomically: true, encoding: .utf8)
try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCtags.path)

setenv("SUIT_CTAGS_PATH", fakeCtags.path, 1)
check(resolveCtagsExecutable() == fakeCtags.path, "SUIT_CTAGS_PATH override wins")

// MARK: - runCtags (stdin file-list plumbing → JSON round-trip)

print("== runCtags ==")
let outputEmpty = SymbolIndex.runCtags(executable: fakeCtags.path, root: tmp.path, files: [])
check(outputEmpty == "", "empty file list → no ctags run, empty output")

let output = SymbolIndex.runCtags(executable: fakeCtags.path, root: tmp.path, files: ["a.swift", "b.swift"])
check(output != nil, "runCtags returns output for a good binary")
let indexed = SymbolIndex.index(SymbolIndex.parseTags(output ?? ""))
check(indexed["sym_a"]?.first?.relativePath == "a.swift", "per-file symbol came through stdin plumbing")
check(indexed["commonSymbol"]?.count == 2, "a symbol defined in both files → two definitions (multi-def)")

// A failing binary (exit 1, no output) → nil so the caller degrades to rg.
let failing = tmp.appendingPathComponent("failing-ctags.sh")
try? "#!/bin/bash\nexit 1\n".write(to: failing, atomically: true, encoding: .utf8)
try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: failing.path)
check(SymbolIndex.runCtags(executable: failing.path, root: tmp.path, files: ["a.swift"]) == nil,
      "a broken ctags (nonzero exit, no output) → nil (rg fallback territory)")

// MARK: - summary

print("")
if failures == 0 {
    print("ALL PASSED")
    exit(0)
} else {
    print("\(failures) ASSERTION(S) FAILED")
    exit(1)
}
