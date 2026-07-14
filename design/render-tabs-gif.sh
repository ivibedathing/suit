#!/bin/bash
# Regenerates design/tabs-drag.gif — the README animation of tab drag & drop
# (chip → edge split / center show, with the live drop-zone preview). Rendered
# offscreen from the real app, same harness pattern as render-reference.sh.
# Re-run and commit the GIF after any tab/pane chrome or drag behavior change.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -O $(ls swift/Sources/suit/*.swift | grep -v '/main.swift$') \
  design/tabs-demo/main.swift \
  $(find swift/Vendor/SwiftTerm -name '*.swift') \
  -o /tmp/suit-tabs-demo
/tmp/suit-tabs-demo design/tabs-drag.gif
