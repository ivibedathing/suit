import Foundation

// Model routing: let a cheap model decide how much model a phase deserves.
//
// Autopilot phases vary enormously in difficulty — "fix a typo in the README"
// and "migrate the pty layer off SwiftTerm" both arrive as a `### Phase N`
// heading plus prose. Paying Opus rates for the former is waste; handing the
// latter to Haiku is a rejected review gate and a respawn, which costs more
// than the model ever saved. So: ask Haiku (~$1/MTok in, a fraction of a cent
// per decision) to read the request and name the tier, and only escalate the
// ones that earn it.
//
// This file is the pure half — prompt composition, verdict parsing, and the
// no-network heuristic. It never runs a process and never touches AppKit, so
// scripts/model-routing-test.sh compiles it standalone (the
// RoadmapParser/FeedbackRouting pattern). ModelRouter.swift is the IO half.
//
// Load-bearing invariant, also stated at openAutopilotRunTab
// (TerminalWindowController+Tasks.swift): an autonomous Autopilot run's model
// is always an explicit choice, never something silently inherited. The
// roadmap's `model:` annotation is the author's opt-in, so routing is what
// happens in its *absence* — `resolve` short-circuits on an annotation and
// never overrides one — and the decision is logged with the source that made
// it. Routing is likewise advisory-only: every failure path lands on a tier
// rather than blocking a run.

// The tiers a request can be routed onto, cheapest first.
//
// Raw values are the CLI aliases, not the pinned model IDs
// (claude-haiku-4-5 / claude-sonnet-5 / claude-opus-4-8). That matches the
// existing surfaces this feeds: the roadmap's `model: haiku` annotation lands
// in ANTHROPIC_MODEL verbatim, and the review gate's Settings field is
// documented as "e.g. --continue or --model opus". Aliases track the current
// generation of each tier, which is what a router wants.
enum ModelTier: String, CaseIterable, Comparable {
    case haiku
    case sonnet
    case opus

    // What the classifier is asked to emit, and what `parse` matches on.
    var verdictToken: String { rawValue.uppercased() }

    // Capability order, so call sites can floor/ceiling a tier rather than
    // hand-rolling comparisons. Declaration order is the capability order.
    var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    static func < (lhs: ModelTier, rhs: ModelTier) -> Bool { lhs.rank < rhs.rank }
}

// Where a tier came from. Surfaced in the Autopilot log so a surprising
// routing decision can be traced to the thing that made it.
enum ModelRoutingSource: Equatable {
    case annotation   // the roadmap's `model:` line — author's explicit choice
    case classifier   // Haiku read the request and picked
    case heuristic    // classifier unavailable/unusable; scored locally
}

struct ModelRoutingDecision: Equatable {
    let tier: ModelTier
    let source: ModelRoutingSource
    let detail: String  // one line, for the Autopilot log

    var logLine: String { "model routing: \(tier.rawValue) (\(detail))" }
}

enum ModelRouting {
    // Requests longer than this are truncated before going to the classifier.
    // A phase body is prose, not a diff; 6k characters is far more than any
    // real spec needs, and the cap keeps a pathological roadmap from turning a
    // cheap decision into an expensive one.
    static let maxRequestCharacters = 6_000

    // MARK: - Classifier prompt

    // The classifier's whole job is one word. Anything it adds is noise we
    // then have to parse around, so the prompt is explicit about the shape and
    // `parse` reads only the final non-blank line — the same convention the
    // review gate uses for its verdict (AutopilotGates.swift).
    //
    // The tier descriptions are written in terms of *work*, not vocabulary:
    // asking "does this sound hard" invites keyword-matching, which is what
    // the heuristic already does (worse). Asking "how many files, how much
    // design, how recoverable is a mistake" is a question a small model can
    // actually answer from the spec text.
    static func classifierPrompt(for request: String) -> String {
        let body = truncate(request)
        return """
        You are a model router for an autonomous coding agent. Read the task \
        below and decide which model tier should execute it. Answer with the \
        cost-appropriate tier, not the most capable one.

        HAIKU — mechanical and local. The change is obvious from the request \
        itself: a typo, a rename, a version bump, a comment, a doc tweak, \
        reformatting. One or two files. A mistake is trivially spotted.

        SONNET — ordinary feature work. A well-specified change across a few \
        files, following patterns the codebase already establishes. Some \
        judgment, but no open design questions.

        OPUS — hard or far-reaching. Architecture or design decisions, \
        concurrency, migrations, cross-cutting refactors, anything touching \
        many files at once, anything where the request states a goal rather \
        than a method, or anything where a subtle mistake would survive review.

        When genuinely torn between two tiers, name the more capable one: a \
        rejected review costs more than the model saved.

        <task>
        \(body)
        </task>

        Respond with exactly one word on its own line — HAIKU, SONNET, or \
        OPUS. No explanation.
        """
    }

    // MARK: - Verdict parsing

    // Reads the classifier's answer off the last non-blank line. Tolerates the
    // small-model failure modes worth tolerating — surrounding punctuation,
    // markdown emphasis, a "Tier:" prefix, any casing — and rejects everything
    // else rather than guessing. A nil here means "fall back to the
    // heuristic", so being strict is cheap and being wrong is not.
    static func parse(_ output: String) -> ModelTier? {
        guard let line = lastNonBlankLine(output) else { return nil }
        let cleaned = line
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "#", with: "")
        // "Tier: OPUS" / "OPUS." / "- opus" all reduce to a bare token.
        let token = cleaned
            .split(whereSeparator: { !$0.isLetter })
            .last
            .map(String.init)?
            .uppercased()
        guard let token else { return nil }
        return ModelTier.allCases.first { $0.verdictToken == token }
    }

    // MARK: - Heuristic fallback

    // What runs when the classifier can't: no claude binary, a timeout, or
    // output that didn't parse. Deliberately crude — this is a backstop, not a
    // second router, and its only real job is to avoid sending a migration to
    // Haiku when the smart path is down.
    //
    // Biased upward on purpose. The asymmetry that governs the whole feature
    // applies here too: under-routing costs a rejected review and a respawn,
    // over-routing costs a few cents. So `sonnet` is the floor unless the
    // request is unmistakably mechanical, and any hard signal jumps to opus.
    static func heuristicTier(for request: String) -> ModelTier {
        let text = request.lowercased()

        // Hard signals: design or blast-radius words that a mechanical change
        // has no reason to contain.
        let hardMarkers = [
            "architect", "migrat", "refactor", "redesign", "rewrite", "port ",
            "concurren", "race condition", "deadlock", "thread-saf", "protocol",
            "cross-cutting", "backward-compat", "backwards-compat", "schema",
            "state machine", "performance", "optimi", "security", "privacy",
        ]
        if hardMarkers.contains(where: text.contains) { return .opus }

        // Soft signals: unmistakably mechanical, and short enough that there's
        // no hidden second half to the request.
        let easyMarkers = [
            "typo", "spelling", "rename", "comment", "whitespace", "formatting",
            "version bump", "bump the version", "doc tweak", "wording",
        ]
        let isShort = request.count < 400
        if isShort, easyMarkers.contains(where: text.contains),
           mentionedPathCount(in: request) <= 1 {
            return .haiku
        }

        // Breadth: a spec that names many files, or runs long, is not a
        // one-liner regardless of its vocabulary.
        if mentionedPathCount(in: request) >= 4 || request.count > 2_500 {
            return .opus
        }
        return .sonnet
    }

    // Rough count of distinct file-ish tokens in the request. Not a parser —
    // it only needs to separate "touches one file" from "touches the world".
    static func mentionedPathCount(in request: String) -> Int {
        let extensions = [".swift", ".sh", ".md", ".json", ".plist", ".yml", ".yaml"]
        var seen = Set<String>()
        for token in request.split(whereSeparator: { $0.isWhitespace || $0 == "(" || $0 == ")" || $0 == "," }) {
            let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: "`\"'*:;."))
            guard extensions.contains(where: cleaned.lowercased().hasSuffix) else { continue }
            seen.insert(cleaned)
        }
        return seen.count
    }

    // MARK: - Resolution

    // The one entry point call sites use. `annotation` is the roadmap's
    // `model:` line (nil when absent); `classifierVerdict` is what the IO half
    // got back from Haiku, or nil if it couldn't get an answer.
    //
    // Order is the whole policy: an author's explicit annotation wins over the
    // classifier, which wins over the heuristic. Nothing here can fail.
    static func resolve(annotation: String?,
                        classifierVerdict: ModelTier?,
                        request: String) -> ModelRoutingDecision {
        if let annotation, !annotation.trimmingCharacters(in: .whitespaces).isEmpty {
            let raw = annotation.trimmingCharacters(in: .whitespaces)
            // An annotation the router doesn't recognize is still honoured —
            // it goes to ANTHROPIC_MODEL verbatim today, and a router that
            // silently dropped an author's pinned model ID would be a
            // regression. Only the *tier* is unknown, not the value.
            let tier = ModelTier(rawValue: raw.lowercased()) ?? .sonnet
            return ModelRoutingDecision(
                tier: tier, source: .annotation,
                detail: "roadmap annotation `model: \(raw)`")
        }
        if let classifierVerdict {
            return ModelRoutingDecision(
                tier: classifierVerdict, source: .classifier,
                detail: "haiku classifier")
        }
        let tier = heuristicTier(for: request)
        return ModelRoutingDecision(
            tier: tier, source: .heuristic,
            detail: "heuristic (classifier unavailable)")
    }

    // A resolved annotation keeps its verbatim value; a routed tier uses its
    // alias. Call sites want the string that goes into ANTHROPIC_MODEL or
    // --model, which is not always `tier.rawValue`.
    static func modelValue(for decision: ModelRoutingDecision, annotation: String?) -> String {
        if decision.source == .annotation, let annotation {
            return annotation.trimmingCharacters(in: .whitespaces)
        }
        return decision.tier.rawValue
    }

    // MARK: - Review gate

    // The reviewer never drops below this, however cheap the phase was. The
    // review gate is a correctness gate — an under-powered reviewer that
    // rubber-stamps is strictly worse than no gate, because it launders a bad
    // change into a merge. The engine's own rule is "ambiguity is never an
    // approve"; this is the same instinct applied to model choice.
    static let reviewFloor: ModelTier = .sonnet

    // Reviewing a change costs about what making it did, so the reviewer
    // follows the worker's routed tier (floored) instead of paying for a
    // second classifier call — the run record already knows what tier the work
    // was routed to.
    static func reviewTier(forWorkerTier tier: ModelTier) -> ModelTier {
        max(tier, reviewFloor)
    }

    // What the review gate passes as `--model`. nil = claude's default.
    //
    // `setting` is the Settings ▸ Autopilot "Reviewer" field: an explicit
    // value there is a human's standing decision and outranks routing, exactly
    // as a roadmap annotation outranks it for the worker. `workerModel` is the
    // run record's model — nil (routing off, or no decision) or an
    // unrecognized custom value both mean "don't route", which preserves
    // today's behaviour rather than guessing.
    static func reviewModel(setting: String, workerModel: String?, enabled: Bool) -> String? {
        let pinned = setting.trimmingCharacters(in: .whitespaces)
        if !pinned.isEmpty { return pinned }
        guard enabled, let workerModel,
              let tier = ModelTier(rawValue: workerModel.trimmingCharacters(in: .whitespaces).lowercased())
        else { return nil }
        return reviewTier(forWorkerTier: tier).rawValue
    }

    // MARK: - Helpers

    static func truncate(_ request: String) -> String {
        guard request.count > maxRequestCharacters else { return request }
        return String(request.prefix(maxRequestCharacters)) + "\n…(truncated)"
    }

    static func lastNonBlankLine(_ text: String) -> String? {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }
}
