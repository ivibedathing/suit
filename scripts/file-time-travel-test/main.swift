import Foundation

// Standalone assertion driver for the file time-travel core (ROADMAP Phase 40),
// compiled against swift/Sources/suit/FileTimeTravel.swift by
// scripts/file-time-travel-test.sh. The harness builds a fixture git repo with a
// file whose lines change across three commits plus an uncommitted working-tree
// edit, then hands us (argv) the repo path, the file's repo-relative path, the
// `git log --follow` capture, and a directory of per-position expected content.
//
// We assert: the timeline maps each scrubber position to the right revision and
// older neighbour; each position renders that revision's exact content (via the
// real `git show <sha>:<path>` argv the app uses); the diff-to-neighbour changed
// lines parse correctly; the working-tree stop equals the on-disk file (so
// leaving time-travel restores it); and the header labels / argv are exact.

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok: \(message)")
    } else {
        print("  FAIL: \(message)")
        failures += 1
    }
}

func runGit(_ repo: String, _ args: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", repo] + args
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = Pipe()
    try! process.run()
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

let args = CommandLine.arguments
guard args.count == 5 else {
    fputs("usage: driver <repo> <relativePath> <logPath> <expectedDir>\n", stderr)
    exit(2)
}
let repo = args[1]
let relPath = args[2]
let logPath = args[3]
let expectedDir = args[4]

// --- Build the timeline from the --follow log -------------------------------
// Format matches GitFileHistory: %H \x1f %h \x1f %an \x1f %at \x1f %s.
let logText = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
var revisions: [TimeTravelRevision] = []
logText.enumerateLines { line, _ in
    let f = line.components(separatedBy: "\u{1f}")
    guard f.count == 5 else { return }
    revisions.append(TimeTravelRevision(sha: f[0], shortSha: f[1], subject: f[4], time: TimeInterval(f[3]) ?? 0))
}

print("== timeline shape ==")
let timeline = TimeTravelTimeline(revisions: revisions)
check(revisions.count == 3, "three commits in the file's history")
check(!timeline.isEmpty, "timeline is non-empty for a tracked file")
check(timeline.stopCount == 4, "stopCount = commits + working tree (4)")
check(timeline.workingTreePosition == 3, "working tree is the rightmost stop")

// Position order: 0 = oldest, 2 = newest (HEAD), 3 = working tree.
let oldest = revisions[2]   // newest-first log → last is oldest
let middle = revisions[1]
let newest = revisions[0]
check(timeline.stop(at: 0) == .commit(oldest), "pos 0 → oldest commit")
check(timeline.stop(at: 1) == .commit(middle), "pos 1 → middle commit")
check(timeline.stop(at: 2) == .commit(newest), "pos 2 → newest (HEAD) commit")
check(timeline.stop(at: 3) == .workingTree, "pos 3 → working tree")
// Clamping.
check(timeline.stop(at: -5) == .commit(oldest), "negative position clamps to oldest")
check(timeline.stop(at: 99) == .workingTree, "over-range position clamps to working tree")

print("== older-neighbour ==")
check(timeline.olderNeighbour(at: 0) == nil, "oldest commit has no older neighbour")
check(timeline.olderNeighbour(at: 1) == oldest, "pos 1 diffs against the oldest")
check(timeline.olderNeighbour(at: 2) == middle, "pos 2 diffs against the middle")
check(timeline.olderNeighbour(at: 3) == newest, "working tree diffs against HEAD")

// --- git argv ---------------------------------------------------------------
print("== git argv ==")
check(TimeTravelGit.showArguments(stop: .commit(newest), relativePath: relPath) == ["show", "\(newest.sha):\(relPath)"],
      "showArguments → git show <sha>:<path>")
check(TimeTravelGit.showArguments(stop: .workingTree, relativePath: relPath) == nil,
      "working tree has no show argv (read off disk)")
check(TimeTravelGit.diffArguments(stop: .workingTree, older: newest, relativePath: relPath) == ["diff", newest.sha, "-U0", "--", relPath],
      "working-tree diff → git diff <head> -U0 -- <path>")
check(TimeTravelGit.diffArguments(stop: .commit(middle), older: oldest, relativePath: relPath) == ["diff", oldest.sha, middle.sha, "-U0", "--", relPath],
      "commit diff → git diff <old> <new> -U0 -- <path>")
check(TimeTravelGit.diffArguments(stop: .commit(oldest), older: nil, relativePath: relPath) == nil,
      "leftmost commit has no diff-to-neighbour argv")

// --- Content + diff-to-neighbour at every position --------------------------
print("== per-position content + diff ==")
// Fixture-known changed new-side lines: nothing at the oldest, line 2 at the
// middle, line 4 at the newest, line 1 in the working tree.
let expectedChanged: [Int: [Int]] = [0: [], 1: [2], 2: [4], 3: [1]]
for position in 0..<timeline.stopCount {
    let stop = timeline.stop(at: position)
    let content: String
    if let showArgs = TimeTravelGit.showArguments(stop: stop, relativePath: relPath) {
        content = runGit(repo, showArgs)
    } else {
        content = (try? String(contentsOfFile: "\(repo)/\(relPath)", encoding: .utf8)) ?? ""
    }
    let expected = (try? String(contentsOfFile: "\(expectedDir)/pos\(position).expected", encoding: .utf8)) ?? "<missing>"
    check(content == expected, "pos \(position) renders that revision's exact content")

    let older = timeline.olderNeighbour(at: position)
    var changed = IndexSet()
    if let diffArgs = TimeTravelGit.diffArguments(stop: stop, older: older, relativePath: relPath) {
        changed = TimeTravelDiff.changedNewLines(inDiff: runGit(repo, diffArgs))
    }
    check(Array(changed).sorted() == expectedChanged[position]!, "pos \(position) diff-to-neighbour changed lines")
}

// Leaving time-travel restores the working-tree view: the rightmost stop's
// content is exactly the on-disk file, which is what the app reloads on exit.
let onDisk = (try? String(contentsOfFile: "\(repo)/\(relPath)", encoding: .utf8)) ?? ""
let wtExpected = (try? String(contentsOfFile: "\(expectedDir)/pos3.expected", encoding: .utf8)) ?? "<missing>"
check(onDisk == wtExpected, "working-tree stop == on-disk file (exit restores it)")

// --- Diff hunk parser edge cases -------------------------------------------
print("== changedNewLines parser ==")
check(TimeTravelDiff.changedNewLines(inDiff: "").isEmpty, "empty diff → no changed lines")
check(Array(TimeTravelDiff.changedNewLines(inDiff: "@@ -1,2 +3,4 @@")).sorted() == [3, 4, 5, 6],
      "+3,4 marks lines 3..6")
check(Array(TimeTravelDiff.changedNewLines(inDiff: "@@ -5,1 +7,0 @@")).sorted() == [7],
      "pure deletion (+c,0) still marks its anchor line")
check(Array(TimeTravelDiff.changedNewLines(inDiff: "@@ -1 +1 @@")).sorted() == [1],
      "count-less hunk header marks a single line")

// --- Header labels ----------------------------------------------------------
print("== header labels ==")
let headHeader = TimeTravelHeader.label(for: .commit(newest), now: newest.time + 3 * 86_400)
check(headHeader.hasPrefix(newest.shortSha), "commit header starts with the short sha")
check(headHeader.contains(newest.subject), "commit header carries the subject")
check(headHeader.contains("3d"), "commit header shows the age (3d)")
check(TimeTravelHeader.label(for: .workingTree, now: 0).contains("Working tree"), "working-tree header labelled")
check(TimeTravelHeader.relativeAge(from: 0, now: 100).isEmpty, "zero time → empty age")
check(TimeTravelHeader.relativeAge(from: 100, now: 100) == "today", "same instant → today")
check(TimeTravelHeader.relativeAge(from: 100, now: 100 + 5 * 86_400) == "5d", "five days → 5d")
check(TimeTravelHeader.relativeAge(from: 100, now: 100 + 60 * 86_400) == "2mo", "sixty days → 2mo")
check(TimeTravelHeader.relativeAge(from: 100, now: 100 + 800 * 86_400) == "2y", "800 days → 2y")

print("")
if failures == 0 {
    print("ALL PASS")
    exit(0)
} else {
    print("\(failures) FAILURE(S)")
    exit(1)
}
