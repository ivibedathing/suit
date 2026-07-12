import Foundation

// Standalone assertion driver for the unified-diff parser core
// (swift/Sources/suit/DiffParser.swift, Foundation-only, no app deps), compiled
// and run by scripts/diffparser-test.sh. Mirrors the RoadmapParser /
// FeedbackRouting / Recipes standalone-test pattern: no app, no UI — just the
// pure parser. Covers line classification, old/new line-number tracking across
// hunks, meta/header handling, context prefix stripping, and changedPaths()
// (including renames, where the b/ side must win).

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok: \(message)")
    } else {
        print("  FAIL: \(message)")
        failures += 1
    }
}

// A small but representative diff: a file header, two meta lines, a hunk header
// starting at old line 10 / new line 10, context, a deletion, an addition, and
// trailing context.
let sample = """
diff --git a/swift/Sources/suit/Foo.swift b/swift/Sources/suit/Foo.swift
index 1234567..89abcde 100644
--- a/swift/Sources/suit/Foo.swift
+++ b/swift/Sources/suit/Foo.swift
@@ -10,4 +10,4 @@ func foo() {
 let a = 1
-let b = 2
+let b = 3
 let c = 4
"""

// MARK: - parse: line classification

print("== UnifiedDiffParser.parse — classification ==")
let parsed = UnifiedDiffParser.parse(sample)

check(parsed.first?.kind == .fileHeader, "first line is a fileHeader")
check(parsed.filter { $0.kind == .meta }.count == 3, "index / --- / +++ are the three meta lines")
check(parsed.contains { $0.kind == .hunkHeader }, "@@ line is a hunkHeader")

let additions = parsed.filter { $0.kind == .addition }
let deletions = parsed.filter { $0.kind == .deletion }
check(additions.count == 1, "exactly one addition")
check(deletions.count == 1, "exactly one deletion")
check(additions.first?.text == "let b = 3", "addition text has the leading + stripped")
check(deletions.first?.text == "let b = 2", "deletion text has the leading - stripped")

// MARK: - parse: line-number tracking

print("== UnifiedDiffParser.parse — line numbers ==")
// Hunk starts at 10/10. Context line "let a = 1" is old 10 / new 10.
let firstContext = parsed.first { $0.kind == .context }
check(firstContext?.oldLine == 10 && firstContext?.newLine == 10,
      "first context line carries both old and new line 10")
// Deletion consumes an old line only; addition consumes a new line only.
check(deletions.first?.oldLine == 11 && deletions.first?.newLine == nil,
      "deletion tracks the old line, no new line")
check(additions.first?.oldLine == nil && additions.first?.newLine == 11,
      "addition tracks the new line, no old line")
// Trailing context "let c = 4" should be old 12 / new 12: the shared context
// (a) advanced both to 11, the deletion advanced old to 12, the addition
// advanced new to 12.
let lastContext = parsed.last { $0.kind == .context }
check(lastContext?.oldLine == 12 && lastContext?.newLine == 12,
      "trailing context re-syncs old and new to line 12")

// MARK: - parse: context prefix + empty lines

print("== UnifiedDiffParser.parse — context text ==")
check(firstContext?.text == "let a = 1", "context line has its single leading space stripped")
// A bare empty context line (no leading space) must still parse as context.
let withBlank = UnifiedDiffParser.parse("@@ -1,2 +1,2 @@\n \n+x")
check(withBlank.contains { $0.kind == .context && $0.text.isEmpty },
      "a blank context line stays context with empty text")

// MARK: - parse: multiple hunks reset the counters

print("== UnifiedDiffParser.parse — multiple hunks ==")
let twoHunks = """
@@ -1,1 +1,1 @@
 a
@@ -50,1 +60,1 @@
 z
"""
let hunked = UnifiedDiffParser.parse(twoHunks)
let contexts = hunked.filter { $0.kind == .context }
check(contexts.count == 2, "two context lines across two hunks")
check(contexts.first?.oldLine == 1 && contexts.first?.newLine == 1,
      "first hunk context is 1/1")
check(contexts.last?.oldLine == 50 && contexts.last?.newLine == 60,
      "second hunk header resets counters to 50/60")

// MARK: - parse: empty input

print("== UnifiedDiffParser.parse — empty ==")
check(UnifiedDiffParser.parse("").isEmpty, "empty diff yields no lines")

// MARK: - changedPaths

print("== UnifiedDiffParser.changedPaths ==")
let multiFile = """
diff --git a/one.swift b/one.swift
index aaa..bbb 100644
--- a/one.swift
+++ b/one.swift
@@ -1 +1 @@
-x
+y
diff --git a/dir/two.swift b/dir/two.swift
index ccc..ddd 100644
--- a/dir/two.swift
+++ b/dir/two.swift
@@ -1 +1 @@
-p
+q
"""
let paths = UnifiedDiffParser.changedPaths(multiFile)
check(paths == ["one.swift", "dir/two.swift"],
      "changedPaths returns each file's b/ path in order")

// A rename: the b/ side (new name) must win.
let renamed = """
diff --git a/old-name.swift b/new-name.swift
similarity index 100%
rename from old-name.swift
rename to new-name.swift
"""
check(UnifiedDiffParser.changedPaths(renamed) == ["new-name.swift"],
      "on a rename, changedPaths takes the new (b/) path")

check(UnifiedDiffParser.changedPaths("").isEmpty, "empty diff has no changed paths")

// MARK: - summary

print("")
if failures == 0 {
    print("ALL PASSED")
    exit(0)
} else {
    print("\(failures) FAILED")
    exit(1)
}
