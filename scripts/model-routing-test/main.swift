import Foundation

// Standalone logic test for the model-routing core. Compiled with only
// swift/Sources/suit/ModelRouting.swift (Foundation-only, no app deps) — the
// RoadmapParser/FeedbackRouting pattern. Exercises verdict parsing (including
// the small-model failure modes it has to tolerate), the resolution
// precedence, the heuristic fallback, and the review-gate tier policy.
// Prints PASS/FAIL lines and exits non-zero on any failure.
//
// ModelRouter.swift (the Process half) is deliberately not compiled in: it
// shells out to claude, which a logic test must never do.

var failures = 0
func check(_ name: String, _ condition: Bool) {
    print("\(condition ? "PASS" : "FAIL"): \(name)")
    if !condition { failures += 1 }
}

// MARK: - Verdict parsing

do {
    check("parse: bare token", ModelRouting.parse("OPUS") == .opus)
    check("parse: lowercase", ModelRouting.parse("haiku") == .haiku)
    check("parse: reads the LAST non-blank line", ModelRouting.parse("""
    Let me think about this.
    It touches many files.

    OPUS
    """) == .opus)
    check("parse: trailing blank lines ignored", ModelRouting.parse("SONNET\n\n  \n") == .sonnet)

    // Failure modes a small model actually produces.
    check("parse: markdown emphasis", ModelRouting.parse("**OPUS**") == .opus)
    check("parse: backticks", ModelRouting.parse("`haiku`") == .haiku)
    check("parse: trailing punctuation", ModelRouting.parse("SONNET.") == .sonnet)
    check("parse: labelled", ModelRouting.parse("Tier: OPUS") == .opus)
    check("parse: bullet", ModelRouting.parse("- opus") == .opus)

    // Rejections — each one falls back to the heuristic, which is safe.
    check("parse: empty → nil", ModelRouting.parse("") == nil)
    check("parse: whitespace → nil", ModelRouting.parse("   \n  ") == nil)
    check("parse: unknown word → nil", ModelRouting.parse("GPT") == nil)
    check("parse: prose without a verdict → nil",
          ModelRouting.parse("I think this one is pretty hard to judge") == nil)
    // A verdict buried above trailing prose is NOT read — the prompt demands
    // the word on its own final line, and guessing here would be worse than
    // falling back.
    check("parse: verdict not on the last line → nil",
          ModelRouting.parse("OPUS\nbecause it touches many files") == nil)
}

// MARK: - Resolution precedence

do {
    let request = "Fix a typo in the README"

    // An annotation is the author's explicit choice and outranks everything.
    let annotated = ModelRouting.resolve(annotation: "opus", classifierVerdict: .haiku, request: request)
    check("resolve: annotation beats classifier", annotated.tier == .opus)
    check("resolve: annotation source", annotated.source == .annotation)

    // A blank annotation is not an annotation.
    let blank = ModelRouting.resolve(annotation: "   ", classifierVerdict: .sonnet, request: request)
    check("resolve: blank annotation ignored", blank.source == .classifier && blank.tier == .sonnet)
    let none = ModelRouting.resolve(annotation: nil, classifierVerdict: .sonnet, request: request)
    check("resolve: nil annotation → classifier", none.source == .classifier)

    // No classifier answer → heuristic, never a failure.
    let fallback = ModelRouting.resolve(annotation: nil, classifierVerdict: nil, request: request)
    check("resolve: no verdict → heuristic", fallback.source == .heuristic)

    // An annotation naming a model the router doesn't know is still honoured
    // verbatim — dropping an author's pinned model ID would be a regression.
    let custom = ModelRouting.resolve(annotation: "claude-opus-4-8", classifierVerdict: nil, request: request)
    check("resolve: unknown annotation keeps source", custom.source == .annotation)
    check("resolve: unknown annotation passes value through",
          ModelRouting.modelValue(for: custom, annotation: "claude-opus-4-8") == "claude-opus-4-8")
    check("resolve: routed tier uses its alias",
          ModelRouting.modelValue(for: none, annotation: nil) == "sonnet")
}

// MARK: - Heuristic fallback

do {
    check("heuristic: typo → haiku",
          ModelRouting.heuristicTier(for: "Fix a typo in the README") == .haiku)
    check("heuristic: rename → haiku",
          ModelRouting.heuristicTier(for: "Rename the `foo` variable to `bar` in Theme.swift") == .haiku)

    check("heuristic: migration → opus",
          ModelRouting.heuristicTier(for: "Migrate the pty layer off SwiftTerm") == .opus)
    check("heuristic: refactor → opus",
          ModelRouting.heuristicTier(for: "Refactor the tab store") == .opus)
    check("heuristic: concurrency → opus",
          ModelRouting.heuristicTier(for: "Fix a race condition in the session watcher") == .opus)

    // A hard marker beats an easy one — "rename" inside a refactor is still a
    // refactor. This is the bias that keeps a migration off haiku.
    check("heuristic: hard marker wins over easy marker",
          ModelRouting.heuristicTier(for: "Rename and refactor the pane protocol") == .opus)

    // Breadth alone escalates, regardless of vocabulary.
    check("heuristic: many files → opus",
          ModelRouting.heuristicTier(for: "Update Pane.swift, TabStore.swift, Theme.swift and PaneTabBarView.swift") == .opus)
    check("heuristic: a typo across many files is not a one-liner",
          ModelRouting.heuristicTier(for: "Fix a typo in A.swift, B.swift, C.swift, D.swift") == .opus)

    // Sonnet is the floor for anything not unmistakably mechanical.
    check("heuristic: ordinary work → sonnet",
          ModelRouting.heuristicTier(for: "Add a checkbox to the settings pane that toggles the footer") == .sonnet)
    check("heuristic: empty request → sonnet (never haiku by default)",
          ModelRouting.heuristicTier(for: "") == .sonnet)

    let long = String(repeating: "Add a small feature. ", count: 200)
    check("heuristic: very long spec → opus", ModelRouting.heuristicTier(for: long) == .opus)
}

// MARK: - Path counting

do {
    check("paths: counts distinct files",
          ModelRouting.mentionedPathCount(in: "Edit A.swift and B.swift") == 2)
    check("paths: dedupes repeats",
          ModelRouting.mentionedPathCount(in: "A.swift then A.swift again") == 1)
    check("paths: strips backticks and punctuation",
          ModelRouting.mentionedPathCount(in: "Edit `Theme.swift`, then build.sh.") == 2)
    check("paths: prose has none",
          ModelRouting.mentionedPathCount(in: "Make the thing faster") == 0)
}

// MARK: - Review gate tier

do {
    // The reviewer never drops to haiku, however cheap the phase was: a
    // rubber-stamp review is worse than no gate.
    check("review: haiku work → sonnet reviewer",
          ModelRouting.reviewTier(forWorkerTier: .haiku) == .sonnet)
    check("review: sonnet work → sonnet reviewer",
          ModelRouting.reviewTier(forWorkerTier: .sonnet) == .sonnet)
    check("review: opus work → opus reviewer",
          ModelRouting.reviewTier(forWorkerTier: .opus) == .opus)

    // The Settings field is a standing human decision and outranks routing.
    check("review: explicit setting wins",
          ModelRouting.reviewModel(setting: "opus", workerModel: "haiku", enabled: true) == "opus")
    check("review: setting wins even with routing off",
          ModelRouting.reviewModel(setting: "opus", workerModel: nil, enabled: false) == "opus")
    check("review: whitespace-only setting is not a setting",
          ModelRouting.reviewModel(setting: "  ", workerModel: "opus", enabled: true) == "opus")

    check("review: routing off → nil (claude's default)",
          ModelRouting.reviewModel(setting: "", workerModel: "haiku", enabled: false) == nil)
    check("review: no worker model → nil",
          ModelRouting.reviewModel(setting: "", workerModel: nil, enabled: true) == nil)
    // A pinned custom model ID isn't a tier we can floor, so don't guess.
    check("review: unrecognized worker model → nil",
          ModelRouting.reviewModel(setting: "", workerModel: "claude-opus-4-8", enabled: true) == nil)
    check("review: follows the routed tier",
          ModelRouting.reviewModel(setting: "", workerModel: "haiku", enabled: true) == "sonnet")
}

// MARK: - Tier ordering

do {
    check("tier: haiku < sonnet < opus", ModelTier.haiku < ModelTier.sonnet && ModelTier.sonnet < ModelTier.opus)
    check("tier: max picks the more capable", max(ModelTier.haiku, ModelTier.opus) == .opus)
}

// MARK: - Prompt composition

do {
    let prompt = ModelRouting.classifierPrompt(for: "Fix a typo")
    check("prompt: embeds the request", prompt.contains("Fix a typo"))
    check("prompt: wraps the request in a tag", prompt.contains("<task>") && prompt.contains("</task>"))
    check("prompt: names every tier",
          ModelTier.allCases.allSatisfy { prompt.contains($0.verdictToken) })
    check("prompt: demands one word", prompt.contains("exactly one word"))

    // A pathological roadmap can't turn a cheap decision into an expensive one.
    let huge = String(repeating: "x", count: ModelRouting.maxRequestCharacters * 3)
    let capped = ModelRouting.classifierPrompt(for: huge)
    check("prompt: truncates an oversized request",
          capped.count < huge.count && capped.contains("(truncated)"))
    let small = "short request"
    check("prompt: leaves a normal request intact", ModelRouting.truncate(small) == small)
}

print(failures == 0 ? "\nAll model-routing checks passed." : "\n\(failures) check(s) FAILED.")
exit(failures == 0 ? 0 : 1)
