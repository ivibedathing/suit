# ROADMAP

Token-cost reduction campaign: cut what Claude sessions spend on this and
every Suit-managed repo, building on the existing filter stack (rtk, the
PostToolUse compress/dedup dispatcher, the savings meter in
`~/.suit/token-savings.jsonl`). Phases in priority order; Autopilot steers
off this file (see `RoadmapParser.swift` for the heading grammar).

### Phase 1 — Token-ignore firewall for heavy paths ✅

The single biggest token trap in a repo is a directory nobody should read
wholesale — vendored dependencies (`swift/Vendor/SwiftTerm/` here), build
output, generated code. Add a per-repo ignore list that keeps those paths
out of the context window:

- A repo opts in with `.claude/token-ignore` at its root: one path prefix
  per line, relative to that root (`#` comments, blank lines ignored).
  Suit's own repo ships one listing `swift/Vendor/`.
- New PreToolUse hook script `scripts/claude/suit-token-ignore.sh`
  (matcher `Read`): a **full-file** Read of a path under an ignored prefix
  is denied with a reason that teaches the model the escape hatches — use
  `offset`/`limit` for a targeted range (range reads always pass through),
  or Grep the path explicitly. Found by walking up from the file toward `/`
  looking for `.claude/token-ignore`; no file → no-op.
- The PostToolUse dispatcher (`suit-posttool-filter.sh`) grows an
  `--ignore` flag: Grep/Glob **results** drop lines/filenames under ignored
  prefixes, replaced by a one-line count marker. A search whose
  `tool_input.path` is explicitly inside an ignored prefix passes through
  untouched (deliberate = allowed).
- Same contract as the existing filters: fail open on every error, jq
  required, `SUIT_TOKEN_FILTERS=off` kill switch, savings logged to
  `~/.suit/token-savings.jsonl` (kind `ignore`).
- Installer: `TokenIgnoreHook.swift` pure core (the RtkHook pattern) owns
  the settings.json transform; one Settings ▸ Claude toggle wires the
  PreToolUse hook and the dispatcher's `--ignore` flag together. Off by
  default. Harness-tested (`scripts/token-ignore-test.sh`), documented in
  `docs/features.md`.

### Phase 2 — Autopilot model & effort routing

Autopilot workers are the most token-hungry surface but always run at the
session default model/effort. Route them per phase:

- `RoadmapParser` learns optional per-phase annotations in the body —
  lines of the form `model: haiku` / `effort: low` (first occurrence wins,
  case-insensitive key, value passed through verbatim) — surfaced as new
  optional fields on `RoadmapPhase`. Pure parsing, harness-covered.
- The engine exports `ANTHROPIC_MODEL` / `CLAUDE_CODE_EFFORT_LEVEL` for a
  worker whose phase carries annotations, so mechanical phases (docs,
  renames, migrations) can run on a cheap model at low effort while design
  phases keep the default.
- The Settings ▸ Claude API env prefix (`ClaudeAPISettings`) additionally
  applies to Autopilot worker launches (today it covers only ✦/task/recipe
  launches), with phase annotations taking precedence over it.
- Review-gate cheapening: skip the headless review when the PR diff is
  byte-identical to the last reviewed diff for the run (hash it), and keep
  the existing `autopilotReviewModel` override documented next to the new
  annotations.

### Phase 3 — Cache hit-rate meter

Prompt-cache misses silently multiply input cost ~10×; today they are
invisible. Surface them:

- A pure `CacheStats` core parses per-turn `usage` blocks
  (`cache_read_input_tokens`, `cache_creation_input_tokens`,
  `input_tokens`) from a session's transcript JSONL (path already known
  via `~/.suit/sessions/<sid>.json` → `transcript_path`) into a rolling
  cache-hit percentage. Foundation-only, harness-tested against fixture
  transcripts.
- Fleet Dashboard rows show the hit rate next to context % and cost;
  a collapsed hit rate (e.g. < 40% over the last 5 turns) tints the metric
  like the fuel-gauge colors and posts one attention-center notice per
  crossing (the BudgetMonitor edge-trigger pattern).
- The likely cause worth naming in the notice: CLAUDE.md / hook scripts /
  MCP config changed mid-session invalidating the prefix — suggest
  finishing or restarting the session.
