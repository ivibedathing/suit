#!/bin/bash
# Session-recipes logic test (ROADMAP Phase 36): compiles the UI-free core
# (swift/Sources/suit/Recipes.swift, Foundation-only, no app deps) with
# scripts/recipes-test/main.swift and runs its assertions — the recipe parser
# (front-matter name / filename fallback), placeholder substitution, the slug,
# the built-in set + file round-trip, and the dir-scoped seed/load IO (seeds an
# empty dir, leaves a populated one alone, missing dir → empty). Mirrors the
# RoadmapParser / FeedbackRouting standalone-test pattern.
#
# Usage: scripts/recipes-test.sh   (run from the repo root)
# Exit: 0 all pass, 1 an assertion failed, 64 compile failure.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DRIVER="$(mktemp -t recipes-test)"
trap 'rm -f "$DRIVER"' EXIT

echo "==> Compiling session-recipes logic test"
if ! swiftc -O \
    "$ROOT/swift/Sources/suit/Recipes.swift" \
    "$ROOT/scripts/recipes-test/main.swift" \
    -o "$DRIVER"; then
    echo "COMPILE FAILED"
    exit 64
fi

echo "==> Running"
"$DRIVER"
