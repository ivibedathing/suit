import Foundation

// Assertion driver for the Phase 34 commit-graph layout. Reads the git log
// output of the fixture repo (built by commit-graph-harness.sh) from the path
// in argv[1], runs the real CommitGraph.parse + layout, and asserts the lanes,
// edges, and ref badges for a history with a fork and a merge. OBSERVE lines +
// nonzero exit on the first failure, matching the other harnesses.

var failures = 0
func check(_ condition: Bool, _ label: String) {
    if condition { print("OBSERVE ok: \(label)") }
    else { print("OBSERVE FAIL: \(label)"); failures += 1 }
}

guard CommandLine.arguments.count >= 2,
      let output = try? String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8) else {
    print("OBSERVE FAIL: could not read git log output")
    exit(1)
}

let commits = CommitGraph.parse(output)
let layout = CommitGraph.layout(commits)

func node(subject: String) -> CommitNode? { layout.nodes.first { $0.subject == subject } }

// The fixture: root → second, then a fork (main-c and feat-d both off second),
// merged back into merge-m. Tag v1.0 on root, branch feature on feat-d,
// HEAD -> main on merge-m.
check(layout.nodes.count == 5, "five commits laid out")
check(layout.laneCount == 2, "history occupies exactly two lanes")

guard let merge = node(subject: "merge-m"),
      let featD = node(subject: "feat-d"),
      let mainC = node(subject: "main-c"),
      let second = node(subject: "second"),
      let root = node(subject: "root") else {
    print("OBSERVE FAIL: expected commits missing (\(layout.nodes.map { $0.subject }))")
    exit(1)
}

// Rows: newest first, merge at the top.
check(merge.row == 0, "the merge commit is newest (row 0)")
check(root.row == layout.nodes.count - 1, "the root commit is oldest (last row)")

// Merge fans out to two parents; the fork point has two children pointing at it.
check(merge.parents.count == 2, "merge-m has two parents")
let intoSecond = layout.edges.filter { $0.parentSha == second.sha }
check(intoSecond.count == 2, "the fork point (second) has two incoming edges")
let outOfMerge = layout.edges.filter { $0.fromRow == merge.row }
check(outOfMerge.count == 2, "the merge has two outgoing edges")

// Lanes: the first-parent line stays in lane 0; the forked feature sits in
// lane 1 and converges back at the fork point.
check(merge.lane == 0, "merge on the main lane (0)")
check(mainC.lane == 0, "main-c continues the main lane (0)")
check(featD.lane == 1, "feat-d takes the second lane (1)")
check(second.lane == 0 && root.lane == 0, "second + root back on lane 0")
check(
    layout.edges.contains { $0.fromRow == featD.row && $0.fromLane == 1 && $0.toRow == second.row && $0.toLane == 0 },
    "feat-d→second edge crosses from lane 1 to lane 0"
)

// Edges resolve to real parent rows.
check(
    layout.edges.allSatisfy { $0.toRow >= 0 && $0.toRow < layout.nodes.count },
    "every edge resolves to a shown parent row"
)
check(!layout.hasTruncatedParents, "no truncated parents in the full fixture")

// Ref badges.
check(merge.isHead && merge.isCurrentBranchTip, "merge-m carries HEAD and the current branch")
check(merge.refs.contains { $0.kind == .currentBranch && $0.name == "main" }, "merge-m badges the current branch main")
check(featD.refs.contains { $0.kind == .branch && $0.name == "feature" }, "feat-d badges the feature branch")
check(root.refs.contains { $0.kind == .tag && $0.name == "v1.0" }, "root badges the v1.0 tag")
check(!second.isHead && second.refs.isEmpty, "an interior commit carries no refs")

// Virtualization: capping keeps the newest N and flags the dropped parents.
let capped = CommitGraph.layout(commits, maxNodes: 2)
check(capped.nodes.count == 2, "cap keeps only the newest two commits")
check(capped.hasTruncatedParents, "capping flags truncated parents for the load-more hint")

if failures == 0 { print("OBSERVE ALL PASS"); exit(0) }
else { print("OBSERVE \(failures) FAILURE(S)"); exit(1) }
