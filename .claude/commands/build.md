---
description: Build the app bundle with ./build.sh and report any errors
allowed-tools: Bash(./build.sh), Bash(swiftc:*), Read
---

Run `./build.sh` from the repo root, which compiles `swift/Sources/suit/` and
assembles `build/Suit.app` (there is no Xcode/SwiftPM project — see AGENTS.md
"Why no SwiftPM").

- If it succeeds, report success and the app bundle path.
- If it fails, show the compiler errors and fix them, then rebuild until green.
  Do not "fix" a build error by deleting functionality — find the real cause.

For a faster inner loop while iterating on non-bundle code, you can instead use
the direct `swiftc` invocation documented in AGENTS.md ("Build & run").
