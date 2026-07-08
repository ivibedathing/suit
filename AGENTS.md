# AGENTS.md

Front-door for coding agents (Claude Code and others). This is the 60-second
orientation; **`CLAUDE.md` is the source of truth** — the full file map, the
architecture, and the rationale live there. Read this first, then reach for
`CLAUDE.md` when you need detail on a specific file or subsystem.

## What Suit is

Suit (**S**top **U**sing **I**DE **T**erminal) is a personal macOS app: a native
AppKit app bundle whose windows host split trees of terminal panes, growing into
a Claude-Code-first cockpit for monorepo work. Swift/AppKit is the whole product
layer. See `ROADMAP.md` for the phased plan and `README.md` for shipped
behavior.

## The rules that bite (read before touching anything)

1. **One worktree + branch per task.** Never work in the main checkout. Use
   `EnterWorktree` (or `git worktree add` under `.claude/worktrees/`). Concurrent
   agents have clobbered each other working directly in main — don't be the next.
2. **Claim a ROADMAP phase before starting it.** Append
   ` 🚧 in progress (<branch>, <date>)` to the `### Phase N` heading on the main
   checkout and commit that one line to main *first*. Skip phases already marked
   `🚧`/`✅`/`⏸`. Flip `🚧`→`✅` when it ships. (`/claim-phase` automates this.)
3. **No SwiftPM, no Xcode project.** The toolchain can't link SwiftPM here (see
   CLAUDE.md "Why no SwiftPM"). Build with `./build.sh` or direct `swiftc`.
   Don't run `xcode-select --install` or create a `.xcodeproj`. Vendor new deps
   as source under `swift/Vendor/` like SwiftTerm.
4. **Document what you ship.** After implementing a phase, update `README.md`
   with the user-facing behavior/shortcuts/settings as part of the same task.

## Build, run, test

```sh
./build.sh                 # compile swift/, assemble build/Suit.app
open build/Suit.app        # launch like a normal Mac app

# faster inner loop (no bundle):
swiftc -O swift/Sources/suit/*.swift \
  $(find swift/Vendor/SwiftTerm -name '*.swift') -o /tmp/suit-shell && /tmp/suit-shell

scripts/test.sh            # fast logic harnesses (feedback-routing + mode-plan)
scripts/test.sh --all      # + the ~4-min autopilot pipeline harness
scripts/test.sh --list     # list harnesses

design/render-reference.sh # regenerate design/phase15-window.png after chrome edits
```

There is no XCTest target. The "tests" are standalone harnesses that compile a
subsystem's pure, UI-free logic against an assertion driver — run them with
`scripts/test.sh` (or the individual `scripts/*-harness.sh` / `*-test.sh`).

## Where things live (the 30-second map — full detail in CLAUDE.md)

- `swift/Sources/suit/` — the AppKit app (the product). ~130 files; entry point
  `main.swift`, app-level dispatch in `AppDelegate*.swift`, one window in
  `TerminalWindowController*.swift`.
  - Panes & tabs: `Pane*.swift`, `PaneContent.swift`, `Tab*.swift`,
    `TabStore.swift`.
  - Content kinds implement `PaneContent`: terminal, `FileViewerPane`,
    `DiffPane`, `TranscriptPane`, `PlanApprovalPane`, `SSHPane`.
  - Sidebar: `SidebarView.swift` + `FileBrowserView`, `SearchView`, `GitView*`,
    `SSHHosts*`, `Notes*`.
  - Claude integration: `Claude*.swift` (sessions, usage, mode, attention),
    `PromptComposer.swift`, plus the producer scripts in `scripts/claude/`.
  - Autopilot (Phase 32): `Autopilot*.swift`, `RoadmapParser.swift`,
    `FeedbackRouting.swift`/`FeedbackInbox.swift`.
- `swift/Vendor/SwiftTerm/` — vendored SwiftTerm source (the pty terminal view).
- `scripts/` — Claude producer scripts (`claude/`) and the logic harnesses.
- `design/` — the visual contract (reference render + generator).
- `Resources/Info.plist` — bundle metadata (id `dev.kosych.suit`); add
  `NS*UsageDescription` keys here for new permissions.
- `.claude/commands/` — repo slash commands: `/build`, `/test`, `/claim-phase`,
  `/render-reference`, `/orient`.

## Conventions

- Match the surrounding code — this repo favors dense, descriptive doc-comments
  at the top of each file explaining the *why*; keep that up when you add files.
- Adding a new pane kind = implement `PaneContent`; the split tree, focus, and
  drag-rearrange all work unchanged.
- Pure, testable logic goes in a Foundation-only file with no app deps (the
  `RoadmapParser`/`AutopilotScheduler`/`FeedbackRouting` pattern) so a harness
  can compile it standalone.
- Privacy invariants are load-bearing: SSH passwords live only in the Keychain,
  never in JSON/logs/saved state; OSC 52 clipboard reads are denied. Don't
  regress these.
