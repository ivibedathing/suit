#!/bin/bash
# Regenerates design/phase15-window.png — the committed reference render of
# the design scenario (pinned terminal + shell + viewer split). Run after any
# chrome change and commit the PNG so drift shows up in review diffs.
set -euo pipefail
cd "$(dirname "$0")/.."
# -j: swiftc runs its per-file frontend jobs serially by default — see build.sh.
swiftc -O -j "$(sysctl -n hw.ncpu 2>/dev/null || echo 4)" \
  $(ls swift/Sources/suit/*.swift | grep -v '/main.swift$') \
  design/reference/main.swift \
  $(find swift/Vendor/SwiftTerm -name '*.swift') \
  -o /tmp/suit-design-reference
/tmp/suit-design-reference design/phase15-window.png
