#!/bin/bash
# Autopilot pipeline harness (ROADMAP Phase 32, STANDALONE.md §4): exercises
# the whole Autopilot pipeline offscreen with everything faked, then asserts
# the §4 contract. The real engine (compiled from the app sources plus
# scripts/autopilot-harness/main.swift, the design/render-reference.sh
# pattern) runs against:
#
#   - a temp $HOME              (sandboxes ~/.suit, UserDefaults, zsh rc files)
#   - a fixture git repo        (2-phase ROADMAP.md — Phase 2 is ⏸-marked —
#                                plus a stub build.sh; a bare "origin" remote)
#   - a fake `claude`           (interactive mode plays the worker: session
#                                file working→done, commit+push, fake gh
#                                pr create — but only after the engine's
#                                missing-PR nudge; `-p` mode is the review
#                                gate: REJECT once, APPROVE afterwards)
#   - a fake `gh`               (argv log + canned JSON for pr list/view/
#                                create; pr merge does a real merge into the
#                                bare origin so post-merge cleanup is honest)
#
# The fakes reach the app three ways: the run tab's zsh finds `claude` first
# on PATH (the temp $HOME's .zshrc prepends the fake bin dir), the headless
# review gate honors SUIT_CLAUDE_PATH, and GitHubCLI honors SUIT_GH_PATH
# (both one-shot static resolution — fine inside the single driver process).
#
# Asserted (spec §4): worktree created at .claude/worktrees/<slug>; worker
# prompt delivered only after the session file appears; nudge sent while the
# PR is missing; rejection findings re-sent into the live session; merge argv
# exactly `pr merge <N> --merge`; worktree + branch gone after the merge; the
# history.jsonl row; the ⏸-marked phase skipped on the next pass.
#
# Re-runnable: everything lives under a fresh mktemp dir, removed on success
# and kept (path printed) on failure. Prints PASS/FAIL per assertion and
# exits nonzero on any FAIL. Takes ~4 minutes: ~2 for swiftc, ~2 for the
# pipeline itself (the engine's own ≥30 s verification pacing is real).
set -euo pipefail
cd "$(dirname "$0")/.."

BASE=${SUIT_HARNESS_BASE:-$(mktemp -d "${TMPDIR:-/tmp}/suit-autopilot-harness.XXXXXX")}
mkdir -p "$BASE"
# Physical path: the engine pins the worker session by comparing the session
# file's cwd (the fake claude's `pwd -P`) against the worktree path it built
# from this base — a symlinked /var or /tmp component would never match.
BASE=$(cd "$BASE" && pwd -P)

TMPHOME="$BASE/home"
FAKEBIN="$BASE/bin"
STATE="$BASE/state"
FIXREPO="$BASE/repo"
BARE="$BASE/origin.git"
DRIVER="$BASE/harness-driver"
DRIVER_LOG="$BASE/driver.log"
AUTOPILOT_DIR="$TMPHOME/.suit/autopilot"
SLUG="phase-1-alpha-widget"

echo "[harness] base: $BASE"
rm -rf "$TMPHOME" "$FAKEBIN" "$STATE" "$FIXREPO" "$BARE"
mkdir -p "$TMPHOME/.suit/sessions" "$FAKEBIN" "$STATE/prs" "$FIXREPO"

# ---------------------------------------------------------------- fixture repo

cat > "$FIXREPO/ROADMAP.md" <<'EOF'
# Fixture Roadmap

### Phase 1 — Alpha widget

Implement the alpha widget.

Verification: ./build.sh exits 0.

### Phase 2 — Beta gadget ⏸

Pre-skipped by the ⏸ steering marker — Autopilot must never start this one.
EOF

cat > "$FIXREPO/CLAUDE.md" <<'EOF'
# Fixture repo rules

Keep the fixture minimal.
EOF

cat > "$FIXREPO/build.sh" <<'EOF'
#!/bin/sh
echo "fixture build ok"
exit 0
EOF
chmod +x "$FIXREPO/build.sh"

git -C "$FIXREPO" init -q -b main
git -C "$FIXREPO" config user.name "Harness"
git -C "$FIXREPO" config user.email "harness@example.com"
git -C "$FIXREPO" add -A
git -C "$FIXREPO" commit -q -m "fixture: initial"
git init -q --bare -b main "$BARE"
git -C "$FIXREPO" remote add origin "$BARE"
git -C "$FIXREPO" push -q -u origin main
git -C "$FIXREPO" remote set-head origin main

# ------------------------------------------------------------------ temp home

# The run tab's zsh (-l -i, HOME mirrored into the pty env) sources this last,
# after /etc/zprofile's path_helper — so the fake bin dir wins even if a real
# claude/gh lives in a system path.
printf 'export PATH="%s:$PATH"\n' "$FAKEBIN" > "$TMPHOME/.zshrc"

# ---------------------------------------------------------------------- fakes

# The pty passes almost no environment through (SwiftTerm mirrors only
# HOME/USER/…), so the fakes read their paths from a config file baked in by
# the __CONFIG__ substitution below, never from env vars.
cat > "$FAKEBIN/harness-config.sh" <<EOF
STATE_DIR="$STATE"
SESS_DIR="$TMPHOME/.suit/sessions"
BARE="$BARE"
GH="$FAKEBIN/gh"
EOF

cat > "$FAKEBIN/claude" <<'FAKECLAUDE'
#!/bin/bash
# Fake `claude` for the Autopilot pipeline harness.
#
# Interactive mode (typed into the run tab's zsh) plays a worker session
# against the engine's real plumbing: writes the session file working→done,
# commits and pushes in the worktree, and calls the fake gh. It deliberately
# skips `gh pr create` on the first pass so the engine's missing-PR nudge
# fires, creates the PR on the nudge, and pushes a fix commit when the
# review-rejection feedback arrives.
#
# `-p` mode (SUIT_CLAUDE_PATH, the headless review gate) consumes the prompt
# from stdin and answers findings + "VERDICT: REJECT" on the first call,
# "VERDICT: APPROVE" afterwards (counter file).
set -u
. __CONFIG__

if [ "${1:-}" = "-p" ]; then
  n=0
  [ -f "$STATE_DIR/review-calls" ] && n=$(cat "$STATE_DIR/review-calls")
  n=$((n + 1))
  echo "$n" > "$STATE_DIR/review-calls"
  cat > "$STATE_DIR/review-prompt-$n.txt"
  if [ "$n" -eq 1 ]; then
    echo "1. Widget.swift:1 — FAKE-FINDING-ALPHA the widget is misaligned; align it"
    echo "VERDICT: REJECT"
  else
    echo "VERDICT: APPROVE"
  fi
  exit 0
fi

WORKTREE=$(pwd -P)
SLUG=$(basename "$WORKTREE")
PHASE=$(printf '%s' "$SLUG" | sed -n 's/^phase-\([0-9]\{1,\}\)-.*$/\1/p')
BRANCH="task/$SLUG"
SID="fake-$SLUG"
SESS_FILE="$SESS_DIR/$SID.json"

note() { echo "$(date +%s) $*" >> "$STATE_DIR/delivery.log"; }

write_session() {
  printf '{"session_id":"%s","state":"%s","cwd":"%s","pid":%d,"updated_at":%d}\n' \
    "$SID" "$1" "$WORKTREE" "$$" "$(date +%s)" > "$SESS_FILE.tmp"
  mv "$SESS_FILE.tmp" "$SESS_FILE"
  note "session-state $1"
}

# §4 "prompt delivered only after the session file appears": hold the session
# file back for 2 s while listening — anything arriving on stdin in this
# window would be a premature delivery (the engine must wait for the file).
if IFS= read -r -t 2 early; then
  note "premature-input $early"
fi
write_session working
note "session-written"

while IFS= read -r line; do
  printf '%s\n' "$line" >> "$STATE_DIR/stdin.log"
  case "$line" in
  *"You are an Autopilot worker session"*)
    note "prompt-received"
    # Everything EXCEPT the PR: ✅-mark this phase's heading, commit, push.
    # The missing PR forces the engine's completion verification to nudge.
    awk -v n="$PHASE" '$0 ~ ("^### Phase " n " ") { print $0 " — ✅ shipped"; next } { print }' \
      ROADMAP.md > ROADMAP.md.new && mv ROADMAP.md.new ROADMAP.md
    echo "widget" > Widget.swift
    git add -A
    git commit -q -m "Phase $PHASE: fake implementation"
    git push -q -u origin "$BRANCH"
    note "work-pushed"
    echo "AUTOPILOT DONE PHASE $PHASE"
    write_session done
    ;;
  *"AUTOPILOT CHECK"*)
    note "nudge-received"
    write_session working
    "$GH" pr create --title "Phase $PHASE: Alpha widget" \
      --body "$(printf 'Fake worker shipped the widget.\n\nAutopilot-Phase: %s\nAutopilot-Slug: %s' "$PHASE" "$SLUG")" \
      >> "$STATE_DIR/delivery.log" 2>&1
    note "pr-created"
    echo "AUTOPILOT DONE PHASE $PHASE"
    write_session done
    ;;
  *"AUTOPILOT REVIEW"*)
    note "rejection-received"
    write_session working
    echo "aligned" >> Widget.swift
    git add -A
    git commit -q -m "Phase $PHASE: fix review findings"
    git push -q origin "$BRANCH"
    note "fix-pushed"
    echo "AUTOPILOT DONE PHASE $PHASE"
    write_session done
    ;;
  esac
done
note "stdin-closed"
FAKECLAUDE

cat > "$FAKEBIN/gh" <<'FAKEGH'
#!/bin/bash
# Fake `gh` for the Autopilot pipeline harness (SUIT_GH_PATH). Records every
# argv to gh-args.log, emits canned JSON for pr list / pr view / pr create
# from the state dir, exits 0 for auth status, and makes `pr merge` honest:
# it performs a real --no-ff merge of the PR branch into the bare origin's
# main (via a scratch clone) so the engine's post-merge ff-sync, worktree
# removal, and next preflight all see a genuinely merged world.
set -eu
. __CONFIG__
PRS="$STATE_DIR/prs"
mkdir -p "$PRS"
printf '%s\n' "$*" >> "$STATE_DIR/gh-args.log"

case "${1:-}" in
auth)
  exit 0
  ;;
pr)
  case "${2:-}" in
  list)
    /usr/bin/python3 - "$PRS" <<'PY'
import json, os, sys
d = sys.argv[1]
prs = [json.load(open(os.path.join(d, f)))
       for f in sorted(os.listdir(d)) if f.endswith(".json")]
print(json.dumps(prs))
PY
    exit 0
    ;;
  create)
    shift 2
    title=""; body=""; head=""
    while [ $# -gt 0 ]; do
      case "$1" in
      --title) title="$2"; shift 2 ;;
      --body) body="$2"; shift 2 ;;
      --head) head="$2"; shift 2 ;;
      *) shift ;;
      esac
    done
    branch="${head:-$(git rev-parse --abbrev-ref HEAD)}"
    n=1
    [ -f "$STATE_DIR/pr-counter" ] && n=$(( $(cat "$STATE_DIR/pr-counter") + 1 ))
    echo "$n" > "$STATE_DIR/pr-counter"
    PR_N="$n" PR_BRANCH="$branch" PR_TITLE="$title" PR_BODY="$body" \
      /usr/bin/python3 - "$PRS" <<'PY'
import json, os, sys
d = sys.argv[1]
e = os.environ
n = int(e["PR_N"])
pr = {"number": n, "headRefName": e["PR_BRANCH"], "state": "OPEN",
      "url": "https://github.example/fake/pull/%d" % n,
      "statusCheckRollup": [], "mergedAt": None,
      "title": e["PR_TITLE"], "body": e["PR_BODY"]}
json.dump(pr, open(os.path.join(d, "%d.json" % n), "w"))
PY
    echo "https://github.example/fake/pull/$n"
    exit 0
    ;;
  view)
    cat "$PRS/${3:?pr number}.json"
    exit 0
    ;;
  merge)
    n="${3:?pr number}"
    f="$PRS/$n.json"
    branch=$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["headRefName"])' "$f")
    scratch=$(mktemp -d "${TMPDIR:-/tmp}/suit-harness-merge.XXXXXX")
    git clone -q "$BARE" "$scratch/clone"
    git -C "$scratch/clone" -c user.name="Fake GH" -c user.email="gh@example.com" \
      merge -q --no-ff -m "Merge pull request #$n from $branch" "origin/$branch"
    git -C "$scratch/clone" push -q origin main
    rm -rf "$scratch"
    /usr/bin/python3 - "$f" <<'PY'
import datetime, json, sys
f = sys.argv[1]
pr = json.load(open(f))
pr["state"] = "MERGED"
pr["mergedAt"] = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump(pr, open(f, "w"))
PY
    exit 0
    ;;
  esac
  ;;
esac
exit 0
FAKEGH

sed -i '' "s|__CONFIG__|$FAKEBIN/harness-config.sh|" "$FAKEBIN/claude" "$FAKEBIN/gh"
chmod +x "$FAKEBIN/claude" "$FAKEBIN/gh"

# --------------------------------------------------------------------- driver

echo "[harness] compiling the driver (swiftc, ~2 min)…"
swiftc -O $(ls swift/Sources/suit/*.swift | grep -v '/main.swift$') \
  scripts/autopilot-harness/main.swift \
  $(find swift/Vendor/SwiftTerm -name '*.swift') \
  -o "$DRIVER"

echo "[harness] running the pipeline (the engine's 30 s verification pacing is real — ~2 min)…"
set +e
env HOME="$TMPHOME" \
    SUIT_GH_PATH="$FAKEBIN/gh" \
    SUIT_CLAUDE_PATH="$FAKEBIN/claude" \
    HARNESS_PROJECT_ROOT="$FIXREPO" \
    HARNESS_TIMEOUT_SECONDS=360 \
    "$DRIVER" > "$DRIVER_LOG" 2>&1
DRIVER_STATUS=$?
set -e
sed 's/^/[driver] /' "$DRIVER_LOG"

# ----------------------------------------------------------------- assertions

DELIVERY="$STATE/delivery.log"
STDIN_LOG="$STATE/stdin.log"
GH_ARGS="$STATE/gh-args.log"

FAIL=0
check() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf 'PASS  %s\n' "$name"
  else
    printf 'FAIL  %s\n' "$name"
    FAIL=$((FAIL + 1))
  fi
}

prompt_after_session() {
  grep -q "premature-input" "$DELIVERY" && return 1
  local ts_session ts_prompt
  ts_session=$(awk '$2 == "session-written" { print $1; exit }' "$DELIVERY")
  ts_prompt=$(awk '$2 == "prompt-received" { print $1; exit }' "$DELIVERY")
  [ -n "$ts_session" ] && [ -n "$ts_prompt" ] && [ "$ts_prompt" -ge "$ts_session" ]
}

worktree_and_branch_gone() {
  [ ! -e "$FIXREPO/.claude/worktrees/$SLUG" ] || return 1
  [ -z "$(git -C "$FIXREPO" branch --list "task/$SLUG")" ] || return 1
  ! git -C "$BARE" show-ref --verify --quiet "refs/heads/task/$SLUG"
}

history_row_ok() {
  /usr/bin/python3 - "$AUTOPILOT_DIR/history.jsonl" "$SLUG" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
slug = sys.argv[2]
assert len(rows) == 1, rows
r = rows[0]
assert r["phase"] == 1 and r["outcome"] == "merged", r
assert r["slug"] == slug and r["branch"] == "task/" + slug, r
assert r["attempts"] == 2, r
assert r["pr_url"] == "https://github.example/fake/pull/1", r
assert r["session_ids"] == ["fake-" + slug], r
assert r["started_at"] <= r["ended_at"], r
PY
}

phase2_never_started() {
  ! grep -q 'run-started phase=2' "$DRIVER_LOG" || return 1
  [ ! -e "$FIXREPO/.claude/worktrees/phase-2-beta-gadget" ] || return 1
  [ "$(grep -c '^pr create' "$GH_ARGS")" = 1 ]
}

check "driver reached doneAllPhases (exit 0)" \
  test "$DRIVER_STATUS" -eq 0
check "worktree created at .claude/worktrees/$SLUG" \
  grep -qF "OBSERVE run-started phase=1 slug=$SLUG worktree=$FIXREPO/.claude/worktrees/$SLUG exists=1" "$DRIVER_LOG"
check "worker prompt delivered only after the session file appeared" \
  prompt_after_session
check "worker prompt carried the phase spec" \
  grep -qF 'Implement ROADMAP.md "Phase 1 — Alpha widget"' "$STDIN_LOG"
check "nudge sent while the PR was missing" \
  grep -qF 'AUTOPILOT CHECK — Phase 1' "$STDIN_LOG"
check "nudge named the missing PR" \
  grep -q 'nudge 1/5 sent.*an open PR' "$AUTOPILOT_DIR/autopilot.log"
check "review rejection feedback re-sent to the live session" \
  grep -qF 'AUTOPILOT REVIEW — Phase 1 attempt 1' "$STDIN_LOG"
check "rejection feedback carried the gate's findings" \
  grep -qF 'FAKE-FINDING-ALPHA' "$STDIN_LOG"
check "merge argv was exactly 'pr merge 1 --merge'" \
  grep -qxF 'pr merge 1 --merge' "$GH_ARGS"
check "build gate ran twice (a log per attempt)" \
  test -s "$AUTOPILOT_DIR/logs/$SLUG/build-1.log" -a -s "$AUTOPILOT_DIR/logs/$SLUG/build-2.log"
check "review gate ran twice (reject, then approve)" \
  test "$(cat "$STATE/review-calls" 2>/dev/null)" = 2
check "first review log ends in VERDICT: REJECT" \
  grep -qxF 'VERDICT: REJECT' "$AUTOPILOT_DIR/logs/$SLUG/review-1.log"
check "second review log ends in VERDICT: APPROVE" \
  grep -qxF 'VERDICT: APPROVE' "$AUTOPILOT_DIR/logs/$SLUG/review-2.log"
check "worktree and branch gone after the merge (local + origin)" \
  worktree_and_branch_gone
check "history.jsonl row is correct" \
  history_row_ok
check "merged ROADMAP marks Phase 1 shipped on main" \
  grep -q '^### Phase 1 — Alpha widget — ✅ shipped$' "$FIXREPO/ROADMAP.md"
check "⏸-marked Phase 2 skipped on the next pass (doneAllPhases)" \
  grep -qF 'OBSERVE done-all-phases' "$DRIVER_LOG"
check "⏸-marked Phase 2 never started (no worktree, no second PR)" \
  phase2_never_started
check "doneAllPhases reason logged (shipped or skipped)" \
  grep -q 'shipped or skipped' "$AUTOPILOT_DIR/autopilot.log"

echo
if [ "$FAIL" -eq 0 ]; then
  echo "[harness] ALL ASSERTIONS PASSED"
  rm -rf "$BASE"
  exit 0
else
  echo "[harness] $FAIL assertion(s) FAILED — artifacts kept at $BASE"
  echo "[harness] --- autopilot.log tail ---"
  tail -40 "$AUTOPILOT_DIR/autopilot.log" 2>/dev/null || true
  echo "[harness] --- delivery.log ---"
  cat "$DELIVERY" 2>/dev/null || true
  exit 1
fi
