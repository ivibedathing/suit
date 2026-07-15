# Development

How to build, test, and hack on [Suit](../README.md). `AGENTS.md` at the repo root is the
source of truth for architecture, the file map, and the load-bearing workflow rules — this page
is the human-oriented setup guide.

## Build & run

There is no Xcode project and no SwiftPM package — Suit is compiled directly with `swiftc` and
assembled into an app bundle by `build.sh` (see the "Why no SwiftPM" note in `AGENTS.md` for the
reasoning).

```sh
./build.sh                 # builds swift/, assembles build/Suit.app (ad-hoc code signed)
open build/Suit.app        # launch like a normal Mac app
```

To iterate on the UI without assembling the bundle, compile the Swift sources straight to a
binary:

```sh
swiftc -O swift/Sources/suit/*.swift \
  $(find swift/Vendor/SwiftTerm -name '*.swift') -o /tmp/suit-shell && /tmp/suit-shell
```

## Testing

There is no XCTest target; the pure, UI-free logic is covered by standalone harnesses — each
compiles the relevant Foundation-only source file(s) against a small assertion driver and runs
it. Run them all with `scripts/test.sh` (fast suite) or `scripts/test.sh --all` (includes the
~4-minute Autopilot pipeline harness) — see the "Testing" section in `AGENTS.md`.

UI/chrome changes are guarded by the committed reference render instead: re-run
`design/render-reference.sh` after chrome edits so visual drift shows up in review diffs.

## Integrations wired from inside the app

Two integrations are set up from inside the app rather than by hand:

- **Claude Code integration** — app menu ▸ *Install Claude Code Integration…* copies the
  bundled statusline / hook scripts to `~/.suit` and merges them into `~/.claude/settings.json`
  (a one-time backup is written first). Required for session awareness and Autopilot.
- **GitHub CLI (`gh`)** — needed for the Branch → PR actions and Autopilot's PR flow.
  Everything degrades gracefully when it's missing.

## Project layout

| Path | What lives there |
| --- | --- |
| `swift/Sources/suit/` | The AppKit app — UI, tabs, sidebar, git / Claude / Autopilot logic |
| `swift/Vendor/SwiftTerm/` | Vendored SwiftTerm source (no SPM — see `AGENTS.md`) |
| `scripts/claude/` | Statusline + session-state hook scripts installed into `~/.suit` |
| `scripts/test.sh` | Runs the standalone logic harnesses (`*-test.sh` / `*-harness.sh`) |
| `design/` | App icon and the committed reference render used to catch visual drift |
| `docs/` | Long-form docs — `features.md` is the full feature reference |
| `Resources/Info.plist` | App bundle metadata and permission usage strings |
| `build.sh` | Builds everything and assembles `build/Suit.app` |
| `AGENTS.md` | Full agent & contributor guidance — architecture, file map, workflow rules |
| `.claude/commands/` | Repo slash commands: `/build`, `/test`, `/find-file`, `/orient`, … |
| `CLAUDE.md` | Stub pointing Claude Code at `AGENTS.md` |

## Contributing workflow

This is a personal project, but the workflow is documented if you want to hack on it:

- Read `AGENTS.md` for the full architecture, the dev loop, and why the build avoids SwiftPM.
- Start each change on its own branch in its own git worktree — never work directly in the main
  checkout — so concurrent Claude Code sessions don't step on each other's edits.
- Run `scripts/test.sh` before committing non-UI changes, and regenerate the reference render
  (`design/render-reference.sh`) after chrome edits.
- After implementing a feature, document the user-facing behavior (shortcuts, settings) in
  [`features.md`](features.md) so it stays a current description of what the app does. Keep the
  README lean — update it only when the change belongs in Highlights or the shortcuts table.
