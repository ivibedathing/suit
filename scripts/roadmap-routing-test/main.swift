import Foundation

// Standalone assertion driver for the phase-routing additions (compiled by
// scripts/roadmap-routing-test.sh with RoadmapParser.swift +
// AutopilotDiffHash.swift, both Foundation-only): the per-phase
// "model:"/"effort:" body annotations that route Autopilot workers onto
// cheaper tiers, and the diff fingerprint behind the review gate's
// unchanged-diff skip. Mirrors the rtk-test driver style.

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok: \(message)")
    } else {
        print("  FAIL: \(message)")
        failures += 1
    }
}

// MARK: - annotation parsing

print("== RoadmapParser.annotation ==")
let annotated = """
### Phase 3 — Rename the widgets

Mechanical sweep, no design judgment needed.

model: haiku
- effort: low

Do the rename everywhere.
"""
let phases = RoadmapParser.phases(in: annotated)
check(phases.count == 1, "the fixture parses to one phase")
check(phases.first?.model == "haiku", "model: haiku is picked up from a bare line")
check(phases.first?.effort == "low", "effort: low is picked up from a '- '-led list line")

let plain = RoadmapParser.phases(in: "### Phase 1 — Plain\n\nJust prose, no annotations.")
check(plain.first?.model == nil, "a phase without annotations has model == nil")
check(plain.first?.effort == nil, "…and effort == nil")

check(RoadmapParser.annotation("model", in: "MODEL: claude-haiku-4-5") == "claude-haiku-4-5",
      "the key is case-insensitive, the value verbatim")
check(RoadmapParser.annotation("model", in: "  model:   spaced-out  ") == "spaced-out",
      "surrounding whitespace is trimmed off key line and value")
check(RoadmapParser.annotation("model", in: "model: first\nmodel: second") == "first",
      "the first occurrence wins")
check(RoadmapParser.annotation("model", in: "the model: something in prose") == nil,
      "a mid-sentence mention is not an annotation (line-anchored)")
check(RoadmapParser.annotation("model", in: "modeling: clay") == nil,
      "a longer word sharing the prefix does not match")
check(RoadmapParser.annotation("model", in: "model:") == nil,
      "an empty value is no annotation")
check(RoadmapParser.annotation("effort", in: "Effort: XHIGH") == "XHIGH",
      "effort parses the same way")

// Annotations must not leak across phases.
let two = """
### Phase 1 — Cheap one
model: haiku

### Phase 2 — Full-price one
Body without annotations.
"""
let pair = RoadmapParser.phases(in: two)
check(pair.count == 2 && pair[0].model == "haiku" && pair[1].model == nil,
      "annotations are per-phase, not inherited")

// The annotation lives in the body, so it must survive into specSnapshot.
check(pair[0].specText.contains("model: haiku"),
      "the annotation stays visible in specText (worker/review contract)")

// MARK: - diff fingerprint

print("== AutopilotDiffHash ==")
let diffA = "diff --git a/x b/x\n+added line\n"
let diffB = "diff --git a/x b/x\n+added line!\n"
check(AutopilotDiffHash.hash(diffA) == AutopilotDiffHash.hash(diffA),
      "the same bytes hash identically (stable across calls)")
check(AutopilotDiffHash.hash(diffA) != AutopilotDiffHash.hash(diffB),
      "a one-byte change produces a different hash")
check(AutopilotDiffHash.hash("") == AutopilotDiffHash.hash(""),
      "the empty diff is stable too")
check(AutopilotDiffHash.hash(diffA).count == 16,
      "the fingerprint is a fixed-width 16-hex-digit string")
// FNV-1a 64 known vector: "a" → af63dc4c8601ec8c (seed/prime regression pin).
check(AutopilotDiffHash.hash("a") == "af63dc4c8601ec8c",
      "FNV-1a 64 matches the published test vector for \"a\"")

if failures > 0 {
    print("\(failures) FAILURE(S)")
    exit(1)
}
print("all assertions passed")
