import Foundation

// Standalone assertion driver for the session-recipes core (ROADMAP Phase 36),
// compiled against swift/Sources/suit/Recipes.swift (Foundation-only) by
// scripts/recipes-test.sh. Mirrors the RoadmapParser / FeedbackRouting
// standalone-test pattern: no app, no UI — the recipe parser, placeholder
// substitution, slug, the built-in set, and the dir-scoped seed/load IO
// (single- and multi-run, round-trip, missing dir).

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok: \(message)")
    } else {
        print("  FAIL: \(message)")
        failures += 1
    }
}

// MARK: - parse

print("== Recipe.parse ==")
let withFront = Recipe.parse(fileName: "x.md", contents: """
---
name: Bug fix
---
Fix this bug: <NAME>
""")
check(withFront.name == "Bug fix", "front-matter name wins over the filename")
check(withFront.body == "Fix this bug: <NAME>", "body is everything after the closing ---")

let noFront = Recipe.parse(fileName: "refactor-thing.md", contents: "Refactor <NAME> in <FILE>")
check(noFront.name == "refactor-thing", "no front matter → name from the filename")
check(noFront.body == "Refactor <NAME> in <FILE>", "no front matter → body is the whole file")

let emptyName = Recipe.parse(fileName: "fallback.md", contents: "---\nname:\n---\nbody")
check(emptyName.name == "fallback", "empty front-matter name falls back to the filename")

// MARK: - filled (placeholder substitution)

print("== Recipe.filled ==")
let recipe = Recipe(name: "r", body: "Task <NAME> in <FILE>\n<SELECTION>\nunrelated <TEXT>")
let filled = recipe.filled(name: "make it fast", selection: "let x = 1", file: "a.swift")
check(filled.contains("Task make it fast in a.swift"), "<NAME> and <FILE> substituted")
check(filled.contains("let x = 1"), "<SELECTION> substituted")
check(filled.contains("unrelated <TEXT>"), "unknown placeholders left untouched")
let empties = recipe.filled(name: "n", selection: "", file: "")
check(!empties.contains("<SELECTION>") && !empties.contains("<FILE>"), "missing context collapses placeholders to empty")

// MARK: - slug

print("== Recipe.slug ==")
check(Recipe.slug(from: "Bug Fix!") == "bug-fix", "spaces/punctuation → single dashes, lowercased")
check(Recipe.slug(from: "  Review  ") == "review", "surrounding space trimmed, no leading/trailing dash")
check(Recipe.slug(from: "***") == "recipe", "all-punctuation name → the 'recipe' fallback")

// MARK: - built-ins

print("== RecipeLibrary.builtIns ==")
let names = RecipeLibrary.builtIns.map { $0.name }
check(names == ["Bug fix", "Feature", "Refactor", "Review"], "the four built-ins, in order")
check(RecipeLibrary.builtIns.allSatisfy { $0.body.contains("<NAME>") }, "every built-in carries the <NAME> placeholder")
// A file round-trips: fileContents → parse recovers the same name.
let roundTrip = Recipe.parse(fileName: "bug-fix.md", contents: RecipeLibrary.fileContents(for: RecipeLibrary.builtIns[0]))
check(roundTrip.name == "Bug fix", "seeded file round-trips its name through parse")

// MARK: - seed / load IO

print("== seedIfEmpty / load ==")
let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("suit-recipes-test-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let dir = tmp.appendingPathComponent("recipes").path

check(RecipeLibrary.load(fromDirectory: dir).isEmpty, "missing dir → no recipes")
check(RecipeLibrary.seedIfEmpty(inDirectory: dir) == true, "empty dir → seeds the built-ins")
let loaded = RecipeLibrary.load(fromDirectory: dir)
check(loaded.count == 4, "four recipes loaded after seeding")
check(loaded.map { $0.name }.sorted() == ["Bug fix", "Feature", "Refactor", "Review"], "seeded recipe names load back")
check(RecipeLibrary.seedIfEmpty(inDirectory: dir) == false, "a populated dir is left alone (no re-seed)")
check(RecipeLibrary.load(fromDirectory: dir).count == 4, "still four after the no-op second seed (no duplicates)")

// MARK: - summary

print("")
if failures == 0 {
    print("ALL PASSED")
    exit(0)
} else {
    print("\(failures) ASSERTION(S) FAILED")
    exit(1)
}
