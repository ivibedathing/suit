import Foundation

// Standalone assertions for the operations-log core (OpsLog.swift). Compiled
// against that one Foundation-only file by scripts/ops-log-test.sh — no app, no
// UI. Mirrors the FeedbackRouting / Activity harness pattern.
//
// What's asserted: argv→label derivation (the thing that instruments dozens of
// call sites from one wrapper, so a regression here silently mislabels the
// whole log), the ring buffer's bound and monotonic sequence, adjacent-run
// collapsing, the rolling-window rollup, filtering, and the formatters.

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if condition {
        print("ok   - \(message)")
    } else {
        print("FAIL - \(message)")
        failures += 1
    }
}

// MARK: - argv → label

func derived(_ executable: String, _ arguments: [String]) -> OpsLabel.Derived {
    OpsLabel.derive(executable: executable, arguments: arguments)
}

let status = derived("/usr/bin/git", ["-C", "/Users/x/Projects/suit", "status", "--porcelain", "-z"])
check(status.kind == .git, "git status derives kind .git")
check(status.label == "git status", "git status label skips -C and its value (got \(status.label))")
check(status.detail == "suit", "git detail is the repo's basename (got \(status.detail ?? "nil"))")

let worktrees = derived("/usr/bin/git", ["-C", "/tmp/repo", "worktree", "list", "--porcelain"])
check(worktrees.label == "git worktree list", "two-word git subcommands keep their verb (got \(worktrees.label))")

let lsFiles = derived("/usr/bin/git", ["-C", "/tmp/repo", "ls-files", "--cached", "--others", "-z"])
check(lsFiles.label == "git ls-files", "a one-word subcommand does not swallow its flags (got \(lsFiles.label))")

// `git log --format=%s base..branch` — the ref after a one-word subcommand is
// an argument, not part of the name.
let log = derived("/usr/bin/git", ["-C", "/tmp/repo", "log", "--format=%s", "main..feature"])
check(log.label == "git log", "a ref after a one-word subcommand is not appended (got \(log.label))")

// -c takes a value too; misreading it would name the operation after a config key.
let configured = derived("/usr/bin/git", ["-c", "color.ui=false", "-C", "/tmp/repo", "diff", "HEAD"])
check(configured.label == "git diff", "-c's value is skipped (got \(configured.label))")
check(configured.detail == "repo", "-C is still found after -c (got \(configured.detail ?? "nil"))")

// A trailing value option with nothing after it must not run off the end.
let truncatedArgs = derived("/usr/bin/git", ["-C"])
check(truncatedArgs.label == "git", "a dangling -C degrades to a bare label, no crash")

let ghList = derived("/opt/homebrew/bin/gh", ["pr", "list", "--json", "number,title"])
check(ghList.kind == .gh && ghList.label == "gh pr list", "gh takes its first two non-flag tokens (got \(ghList.label))")

let rg = derived("/usr/bin/rg", ["--json", "--ignore-case", "--regexp", "TabStore"])
check(rg.kind == .search && rg.label == "ripgrep", "rg derives kind .search")
check(rg.detail == "TabStore", "rg's detail is the pattern (got \(rg.detail ?? "nil"))")

let ctags = derived("/opt/homebrew/bin/ctags", ["-f", "-", "--fields=+n", "-L", "-"])
check(ctags.kind == .symbols && ctags.label == "ctags", "ctags derives kind .symbols")

let shell = derived("/bin/zsh", ["-l", "-c", "command -v gh"])
check(shell.label == "shell" && shell.detail == "command -v gh", "a -c shell carries its command as detail")

let unknown = derived("/usr/bin/sw_vers", ["-productVersion"])
check(unknown.kind == .process && unknown.label == "sw_vers", "an unknown binary falls back to its basename")

// MARK: - Ring buffer

let log1 = OpsLog()
for i in 0..<(OpsLog.capacity + 50) {
    log1.record(kind: .git, label: "git status \(i)", startedAt: 100, duration: 0.01, outcome: .ok)
}
let kept = log1.snapshot
check(kept.count == OpsLog.capacity, "the buffer is bounded at capacity (got \(kept.count))")
check(kept.first?.label == "git status 50", "the oldest records are the ones dropped (got \(kept.first?.label ?? "nil"))")
check(kept.last?.seq ?? 0 > kept.first?.seq ?? 0, "sequence numbers increase")
// Sequence keeps counting past a trim, so rows stay uniquely identifiable.
check(kept.last?.seq == UInt64(OpsLog.capacity + 50), "seq counts every record, trimmed or not")

let paused = OpsLog()
paused.isPaused = true
paused.record(kind: .git, label: "git status", startedAt: 0, duration: 0, outcome: .ok)
check(paused.snapshot.isEmpty, "a paused log records nothing")
paused.isPaused = false
paused.record(kind: .git, label: "git status", startedAt: 0, duration: 0, outcome: .ok)
check(paused.snapshot.count == 1, "unpausing resumes recording")

let cleared = OpsLog()
cleared.record(kind: .git, label: "git status", startedAt: 0, duration: 0, outcome: .ok)
cleared.clear()
check(cleared.snapshot.isEmpty, "clear() empties the buffer")

// MARK: - measure()

let measured = OpsLog()
let value: String? = measured.measure(
    kind: .git, label: "git status", trigger: "file change",
    outcome: { $0 == nil ? .failed : .ok }
) { "output" }
check(value == "output", "measure() returns the body's value")
check(measured.snapshot.first?.outcome == .ok, "measure() derives outcome from the result")
check(measured.snapshot.first?.trigger == "file change", "measure() carries the trigger through")

let failing = OpsLog()
let nothing: String? = failing.measure(kind: .git, label: "git status", outcome: { $0 == nil ? .failed : .ok }) { nil }
check(nothing == nil && failing.snapshot.first?.outcome == .failed, "a nil result records as failed")

// MARK: - Ambient trigger

check(OpsLog.currentTrigger == nil, "no ambient trigger by default")
OpsLog.withTrigger("tab shown") {
    check(OpsLog.currentTrigger == "tab shown", "withTrigger sets the ambient trigger")
    OpsLog.withTrigger("nested") {
        check(OpsLog.currentTrigger == "nested", "nested triggers shadow the outer one")
    }
    check(OpsLog.currentTrigger == "tab shown", "the outer trigger is restored after nesting")
}
check(OpsLog.currentTrigger == nil, "the trigger does not leak past its scope")

// MARK: - Collapsing

func rec(_ seq: UInt64, _ label: String, kind: OpsKind = .git, detail: String? = nil,
         trigger: String? = nil, at t: TimeInterval = 0, duration: TimeInterval = 0.1,
         outcome: OpsOutcome = .ok) -> OpsRecord {
    OpsRecord(seq: seq, kind: kind, label: label, detail: detail, trigger: trigger,
              startedAt: t, duration: duration, outcome: outcome)
}

// Three identical status runs, then a gh call, then one more status run: the
// trailing run must not merge into the leading one across the gh row.
let burst = [
    rec(1, "git status", detail: "suit", at: 10),
    rec(2, "git status", detail: "suit", at: 11),
    rec(3, "git status", detail: "suit", at: 12),
    rec(4, "gh pr list", kind: .gh, at: 13),
    rec(5, "git status", detail: "suit", at: 14),
]
let rows = OpsCollapse.rows(burst)
check(rows.count == 3, "adjacent identical runs collapse into one row (got \(rows.count))")
check(rows[0].record.label == "git status" && rows[0].count == 1, "newest-first: the lone trailing run leads")
check(rows[1].record.label == "gh pr list", "the interleaved gh row separates the runs")
check(rows[2].count == 3, "the leading run of three collapses (got \(rows[2].count))")
check(abs(rows[2].totalDuration - 0.3) < 0.0001, "a collapsed row sums its durations")
check(rows[2].record.seq == 3, "a collapsed row is represented by its newest record")
check(rows[2].isCollapsed && !rows[0].isCollapsed, "isCollapsed distinguishes a run from a single")

// A failure inside a run of successes is its own row — that's the one you came for.
let withFailure = [
    rec(1, "git status", at: 10),
    rec(2, "git status", at: 11, outcome: .failed),
    rec(3, "git status", at: 12),
]
check(OpsCollapse.rows(withFailure).count == 3, "a differing outcome breaks a run")

// Differing triggers don't merge either — the cause is the interesting column.
let differentTriggers = [
    rec(1, "git status", trigger: "file change", at: 10),
    rec(2, "git status", trigger: "tab shown", at: 11),
]
check(OpsCollapse.rows(differentTriggers).count == 2, "a differing trigger breaks a run")

// The limit caps rows, not records: a run being collapsed still consumes only
// one row of the budget.
let capped = OpsCollapse.rows(burst, limit: 2)
check(capped.count == 2, "limit caps the number of rows (got \(capped.count))")

check(OpsCollapse.rows([]).isEmpty, "collapsing nothing yields nothing")

// MARK: - Rollup

let now: TimeInterval = 1_000
let window: TimeInterval = 60
let recent = [
    rec(1, "git status", at: now - 10, duration: 0.12),
    rec(2, "gh pr list", kind: .gh, at: now - 20, duration: 1.4),
    rec(3, "git status", at: now - 30, duration: 0.1, outcome: .failed),
    rec(4, "git status", at: now - 500, duration: 5.0),   // outside the window
]
let rollup = OpsRollup.over(recent, now: now, window: window)
check(rollup.runs == 3, "the rollup counts only records inside the window (got \(rollup.runs))")
check(rollup.failures == 1, "the rollup counts failures")
check(abs(rollup.totalDuration - 1.62) < 0.0001, "the rollup sums durations inside the window")
check(!rollup.summary(window: window).isEmpty, "the rollup renders a summary")
check(OpsRollup.over(recent, now: now, window: 1).isEmpty, "an empty window rolls up to nothing")
// The boundary itself counts, so a fabricated round timestamp isn't a coin flip.
check(OpsRollup.over([rec(1, "x", at: now - window)], now: now, window: window).runs == 1,
      "a record exactly at the window's edge is included")
// A record stamped in the future (a clock adjustment mid-pass) is not counted
// as recent work.
check(OpsRollup.over([rec(1, "x", at: now + 10)], now: now, window: window).runs == 0,
      "a future-stamped record is excluded")

// MARK: - Filtering

let mixed = [
    rec(1, "git status", detail: "suit", trigger: "file change"),
    rec(2, "gh pr list", kind: .gh, detail: "suit"),
    rec(3, "ripgrep", kind: .search, detail: "TabStore"),
]
check(OpsFilter.apply(mixed, kind: .git).count == 1, "filtering by kind")
check(OpsFilter.apply(mixed, kind: nil).count == 3, "a nil kind matches everything")
check(OpsFilter.apply(mixed, query: "tabstore").count == 1, "the query matches detail, case-insensitively")
check(OpsFilter.apply(mixed, query: "file change").count == 1, "the query matches the trigger")
check(OpsFilter.apply(mixed, query: "   ").count == 3, "a whitespace-only query filters nothing")
check(OpsFilter.apply(mixed, kind: .gh, query: "suit").count == 1, "kind and query combine")
check(OpsFilter.kinds(in: mixed) == [.git, .gh, .search], "present kinds come back in declaration order")

// MARK: - Formatting

check(OpsFormat.duration(0.0000001) == "<1ms", "sub-millisecond durations floor to <1ms")
check(OpsFormat.duration(0.12) == "120ms", "sub-second durations render as whole milliseconds")
check(OpsFormat.duration(1.44) == "1.4s", "seconds render to one decimal")
check(OpsFormat.duration(125) == "2m 05s", "minutes render with a zero-padded remainder (got \(OpsFormat.duration(125)))")
check(OpsFormat.age(5) == "5s", "ages under a minute render in seconds")
check(OpsFormat.age(300) == "5m", "ages under an hour render in minutes")
check(OpsFormat.age(7200) == "2h", "ages under a day render in hours")
check(OpsFormat.age(172_800) == "2d", "ages past a day render in days")

print(failures == 0 ? "\nAll ops-log assertions passed." : "\n\(failures) assertion(s) failed.")
exit(failures == 0 ? 0 : 1)
