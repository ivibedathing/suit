#!/bin/bash
# Mode + plan-approval logic harness (ROADMAP Phase 26). Compiles the real
# ClaudeMode.swift and PlanParsing.swift (the pure control logic the phase
# rests on) against a tiny ClaudeSession stub plus the assertion driver in
# scripts/mode-plan-harness/main.swift, then runs it. No app, no UI — just the
# switch payloads, plan parsing, and approval payloads the phase's verification
# calls out. Exits nonzero on any failed assertion.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
src="$root/swift/Sources/suit"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ClaudeMode.effectiveMode(for:) is the only app type these pure files touch;
# stub it with just the fields it reads.
cat > "$tmp/stub.swift" <<'EOF'
struct ClaudeSession {
    let id: String
    let permissionMode: ClaudeMode?
}
EOF

swiftc -O \
  "$src/ClaudeMode.swift" \
  "$src/PlanParsing.swift" \
  "$tmp/stub.swift" \
  "$root/scripts/mode-plan-harness/main.swift" \
  -o "$tmp/harness"

"$tmp/harness"
