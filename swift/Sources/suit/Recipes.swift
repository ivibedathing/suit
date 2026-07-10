import Foundation

// Session task templates / recipes: the Steer pillar. Earlier work
// productized worktree tasks and added the prompt library; this fuses
// them — one command spins a worktree + `claude` + a parameterized prompt, so a
// bugfix / feature / refactor / review each launches in a single keystroke.
//
// Recipes are files under ~/.suit/recipes/*.md (the ~/.suit/prompts pattern):
// an optional `---`-fenced front-matter `name:` plus a body prompt carrying
// <NAME> / <SELECTION> / <FILE> placeholders. A few built-ins are seeded on
// first run when the directory is empty.
//
// The parsing, placeholder substitution, built-in set, and the (dir-scoped) seed
// / load IO are all here and Foundation-only so scripts/recipe-test.sh can
// compile and assert them in isolation — the RoadmapParser / FeedbackRouting
// standalone pattern. RecipesStore.shared layers the ~/.suit path + a didUpdate
// notification on top for the app.

struct Recipe: Equatable {
    let name: String
    let body: String

    // Parses one recipe file. A leading `---` front-matter block contributes a
    // `name:` (everything after the closing `---` is the body); without it the
    // whole file is the body and the file's base name is the display name.
    static func parse(fileName: String, contents: String) -> Recipe {
        let fallbackName = (fileName as NSString).deletingPathExtension
        var name: String?
        var body = contents

        let lines = contents.components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            var closingIndex: Int?
            for index in 1..<lines.count where lines[index].trimmingCharacters(in: .whitespaces) == "---" {
                closingIndex = index
                break
            }
            if let closingIndex {
                for index in 1..<closingIndex {
                    let line = lines[index]
                    if let range = line.range(of: "name:") {
                        let value = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                        if !value.isEmpty { name = value }
                    }
                }
                body = lines[(closingIndex + 1)...].joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        let resolvedName = (name?.isEmpty == false ? name! : fallbackName)
        return Recipe(name: resolvedName, body: body)
    }

    // Substitutes the recipe placeholders. Missing context (no selection / no
    // file) collapses to empty rather than leaving a literal `<SELECTION>` in the
    // prompt. Order matters only in that each token is replaced once; recipe
    // bodies, not user values, own the placeholder vocabulary.
    func filled(name: String, selection: String, file: String) -> String {
        body
            .replacingOccurrences(of: "<NAME>", with: name)
            .replacingOccurrences(of: "<SELECTION>", with: selection)
            .replacingOccurrences(of: "<FILE>", with: file)
    }

    // The filename a recipe seeds to: a filesystem-safe slug of its name. Only
    // used for the seeded `.md` file name (the worktree the recipe later spins
    // derives its own slug from the task name via WorktreeTasks.slug).
    var slug: String { Recipe.slug(from: name) }

    static func slug(from name: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        let lowered = name.lowercased()
        var result = ""
        var lastWasDash = false
        for scalar in lowered.unicodeScalars {
            if allowed.contains(scalar) && scalar != "-" {
                result.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash && !result.isEmpty {
                result.append("-")
                lastWasDash = true
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return result.isEmpty ? "recipe" : result
    }
}

enum RecipeLibrary {
    // The built-ins seeded when the recipes directory is empty. Each is written
    // as a front-matter file so the seeded set doubles as documentation of the
    // format. The review recipe echoes the reviewer-agent lane — a
    // read-only review pass — but stays a manual, interactive launcher (no
    // gating, no auto-merge, unlike Autopilot).
    static let builtIns: [Recipe] = [
        Recipe(name: "Bug fix", body: """
        Fix this bug: <NAME>

        Relevant file: <FILE>

        <SELECTION>

        Reproduce it first, add a failing test where practical, apply the fix, then
        verify the fix and that nothing else regressed.
        """),
        Recipe(name: "Feature", body: """
        Implement this feature: <NAME>

        Relevant file: <FILE>

        <SELECTION>

        Plan the change briefly, implement it following the surrounding code's
        conventions, and verify it end-to-end before finishing.
        """),
        Recipe(name: "Refactor", body: """
        Refactor: <NAME>

        Target file: <FILE>

        <SELECTION>

        Keep behavior identical — no functional changes. Improve structure,
        naming, and readability, and run the tests to confirm nothing broke.
        """),
        Recipe(name: "Review", body: """
        Review the changes on this branch: <NAME>

        <SELECTION>

        Go over correctness, edge cases, error handling, and style. Report your
        findings grouped by severity. This is a read-only review — do not modify
        the code.
        """),
    ]

    // The on-disk form of a recipe: a front-matter `name:` + the body, so a
    // round-trip through parse() recovers the same name.
    static func fileContents(for recipe: Recipe) -> String {
        "---\nname: \(recipe.name)\n---\n\(recipe.body)\n"
    }

    // Seeds the built-ins into `directory` only when it holds no recipe files
    // yet (fresh install, or the user emptied it deliberately keeps it empty
    // only until the next seed — matching the prompt library's "files, not a
    // settings UI" spirit: a populated dir is left alone). Returns whether it
    // seeded.
    @discardableResult
    static func seedIfEmpty(inDirectory directory: String) -> Bool {
        let fm = FileManager.default
        let existing = (try? fm.contentsOfDirectory(atPath: directory)) ?? []
        if existing.contains(where: { $0.hasSuffix(".md") }) { return false }
        try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for recipe in builtIns {
            let path = directory + "/" + recipe.slug + ".md"
            try? fileContents(for: recipe).write(toFile: path, atomically: true, encoding: .utf8)
        }
        return true
    }

    // Loads every *.md in `directory` as a recipe, sorted by name. Missing dir →
    // empty (the caller seeds first).
    static func load(fromDirectory directory: String) -> [Recipe] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory) else { return [] }
        return names.filter { $0.hasSuffix(".md") }.sorted().compactMap { name in
            guard let contents = try? String(contentsOfFile: directory + "/" + name, encoding: .utf8) else { return nil }
            return Recipe.parse(fileName: name, contents: contents)
        }
    }
}

// The app-facing store: resolves ~/.suit/recipes ($HOME first so harnesses can
// sandbox it), seeds the built-ins on first use, and posts didUpdate — the
// FavoritesStore / NotesStore shape.
final class RecipesStore {
    static let shared = RecipesStore()
    static let didUpdate = Notification.Name("dev.kosych.suit.RecipesDidUpdate")

    private(set) var recipes: [Recipe] = []

    var directory: String {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return home + "/.suit/recipes"
    }

    init() {
        reload()
    }

    func reload() {
        RecipeLibrary.seedIfEmpty(inDirectory: directory)
        recipes = RecipeLibrary.load(fromDirectory: directory)
        NotificationCenter.default.post(name: Self.didUpdate, object: self)
    }
}
