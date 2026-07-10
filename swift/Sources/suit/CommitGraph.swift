import Foundation

// Commit-graph layout, the UI-free, standalone-compilable
// core (the RoadmapParser / FeedbackRouting / SubagentTree pattern,
// Foundation-only): parses `git log --all --date-order` output and assigns
// each commit a lane (column) with edges to its parents, so the pane can draw
// the DAG as a thing you read and click. The lane assignment is the classic
// swim-lane algorithm — process newest-first, keep a set of active lanes each
// waiting for the next commit it expects, converge forks and fan out merges —
// verified against a fixture repo by scripts/commit-graph-harness.sh.

// One commit as parsed from the log, before layout.
struct RawCommit {
    let sha: String
    let parents: [String]
    let author: String
    let timestamp: Int      // author epoch seconds
    let refNames: [String]  // raw %D tokens ("HEAD -> main", "tag: v1", …)
    let subject: String
}

enum CommitRefKind {
    case head          // detached HEAD sitting on this commit
    case branch        // a local branch tip
    case currentBranch // the branch HEAD points at ("HEAD -> main")
    case remoteBranch  // e.g. origin/main
    case tag
}

struct CommitRef: Equatable {
    let kind: CommitRefKind
    let name: String
}

// A laid-out commit: its lane (column) and row (0 = newest, top).
struct CommitNode {
    let sha: String
    let shortSha: String
    let subject: String
    let author: String
    let timestamp: Int
    let parents: [String]
    let refs: [CommitRef]
    let isHead: Bool             // HEAD (detached or via its branch) is here
    let isCurrentBranchTip: Bool // the checked-out branch's tip
    let row: Int
    let lane: Int
}

// A parent link, endpoints resolved to (row, lane) so the view can draw it.
struct CommitEdge: Equatable {
    let fromRow: Int
    let fromLane: Int
    let toRow: Int
    let toLane: Int
    let parentSha: String
}

struct CommitGraphLayout {
    let nodes: [CommitNode]
    let edges: [CommitEdge]
    let laneCount: Int
    // Parents referenced by a shown commit but not themselves shown (history
    // truncated by the node cap or a shallow clone) — the "load more" hint.
    let hasTruncatedParents: Bool
}

enum CommitGraph {
    // Field + record separators for the --pretty format below; ASCII unit /
    // record separators never occur in commit metadata.
    static let fieldSeparator = "\u{1f}"
    static let recordSeparator = "\u{1e}"

    // The git invocation the pane runs (kept here so the harness and the pane
    // format identically): all refs, date-order, one record per commit.
    static let prettyFormat =
        "%H\u{1f}%P\u{1f}%an\u{1f}%at\u{1f}%D\u{1f}%s\u{1e}"
    static var logArguments: [String] {
        ["log", "--all", "--date-order", "--pretty=format:\(prettyFormat)"]
    }

    // Parses the `git log` output (records separated by \x1e, fields by \x1f).
    static func parse(_ output: String) -> [RawCommit] {
        output
            .components(separatedBy: recordSeparator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap { record in
                let fields = record.components(separatedBy: fieldSeparator)
                guard fields.count >= 6 else { return nil }
                let sha = fields[0]
                guard !sha.isEmpty else { return nil }
                let parents = fields[1].split(separator: " ").map(String.init)
                let refNames = fields[4]
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                return RawCommit(
                    sha: sha,
                    parents: parents,
                    author: fields[2],
                    timestamp: Int(fields[3]) ?? 0,
                    refNames: refNames,
                    subject: fields[5]
                )
            }
    }

    // Parses one %D ref list into typed refs, and reports whether HEAD (and the
    // current branch it points at) live here.
    static func refs(from tokens: [String]) -> (refs: [CommitRef], isHead: Bool, currentBranch: Bool) {
        var refs: [CommitRef] = []
        var isHead = false
        var currentBranch = false
        for token in tokens {
            if token == "HEAD" {
                isHead = true
                refs.append(CommitRef(kind: .head, name: "HEAD"))
            } else if token.hasPrefix("HEAD -> ") {
                isHead = true
                currentBranch = true
                let name = String(token.dropFirst("HEAD -> ".count))
                refs.append(CommitRef(kind: .currentBranch, name: name))
            } else if token.hasPrefix("tag: ") {
                refs.append(CommitRef(kind: .tag, name: String(token.dropFirst("tag: ".count))))
            } else if token.contains("/") {
                refs.append(CommitRef(kind: .remoteBranch, name: token))
            } else {
                refs.append(CommitRef(kind: .branch, name: token))
            }
        }
        return (refs, isHead, currentBranch)
    }

    // Assigns lanes and resolves edges. `commits` must be in the log's
    // date-order (newest first). Optionally cap at `maxNodes` (virtualization);
    // parents beyond the cap flag `hasTruncatedParents`.
    static func layout(_ commits: [RawCommit], maxNodes: Int? = nil) -> CommitGraphLayout {
        let shown: [RawCommit]
        if let maxNodes, commits.count > maxNodes {
            shown = Array(commits.prefix(maxNodes))
        } else {
            shown = commits
        }
        let rowOfSha: [String: Int] = Dictionary(
            shown.enumerated().map { ($0.element.sha, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )

        // Active lanes: each holds the sha it next expects, or nil when free.
        var lanes: [String?] = []
        var laneCount = 0

        func firstFreeLane() -> Int {
            if let idx = lanes.firstIndex(where: { $0 == nil }) { return idx }
            lanes.append(nil)
            return lanes.count - 1
        }

        var placedLane = [Int](repeating: 0, count: shown.count)

        for (row, commit) in shown.enumerated() {
            // This commit's lane: the leftmost active lane already waiting for
            // it (children converge there); else a fresh lane.
            let myLane: Int
            if let existing = lanes.firstIndex(where: { $0 == commit.sha }) {
                myLane = existing
            } else {
                myLane = firstFreeLane()
            }
            // Free any other lanes that were also waiting for this sha — those
            // are additional children whose edges converge here (a fork point).
            for l in lanes.indices where lanes[l] == commit.sha && l != myLane {
                lanes[l] = nil
            }
            placedLane[row] = myLane

            // Route parents: the first continues this lane; extra parents (a
            // merge) fan out into their own lanes, reusing one already waiting.
            if commit.parents.isEmpty {
                lanes[myLane] = nil
            } else {
                lanes[myLane] = commit.parents[0]
                for parent in commit.parents.dropFirst() {
                    if lanes.contains(where: { $0 == parent }) { continue }
                    let pLane = firstFreeLane()
                    lanes[pLane] = parent
                }
            }
            laneCount = max(laneCount, lanes.count)
        }

        // Build nodes now that every lane is known.
        var nodes: [CommitNode] = []
        nodes.reserveCapacity(shown.count)
        for (row, commit) in shown.enumerated() {
            let parsed = refs(from: commit.refNames)
            nodes.append(CommitNode(
                sha: commit.sha,
                shortSha: String(commit.sha.prefix(7)),
                subject: commit.subject,
                author: commit.author,
                timestamp: commit.timestamp,
                parents: commit.parents,
                refs: parsed.refs,
                isHead: parsed.isHead,
                isCurrentBranchTip: parsed.currentBranch,
                row: row,
                lane: placedLane[row]
            ))
        }

        // Edges: each shown commit to each parent that is also shown.
        var edges: [CommitEdge] = []
        var truncated = false
        for node in nodes {
            for parent in node.parents {
                guard let parentRow = rowOfSha[parent] else { truncated = true; continue }
                edges.append(CommitEdge(
                    fromRow: node.row,
                    fromLane: node.lane,
                    toRow: parentRow,
                    toLane: nodes[parentRow].lane,
                    parentSha: parent
                ))
            }
        }

        return CommitGraphLayout(nodes: nodes, edges: edges, laneCount: max(1, laneCount), hasTruncatedParents: truncated)
    }
}
