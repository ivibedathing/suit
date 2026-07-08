import Foundation

// ROADMAP Phase 40 — File time-travel scrubber. The UI-free core (the
// RoadmapParser / CommitGraph / Recipes pattern, Foundation-only so
// scripts/file-time-travel-test.sh can compile it standalone): it builds the
// ordered timeline of a file's revisions from its history, maps each scrubber
// position to the revision it renders and the older neighbour it diffs against,
// composes the git argv for both, and parses a unified diff's changed new-side
// lines for the gutter marks. All the git IO lives in the app layer
// (FileViewerPane+TimeTravel.swift); this file is pure decisions and formatting.

// One revision on the timeline — a lightweight, Foundation-only mirror of
// GitFileHistory's FileCommit (which is a Cocoa file). The app builds these
// from FileCommits when it enters time-travel.
struct TimeTravelRevision: Equatable {
    let sha: String
    let shortSha: String
    let subject: String
    let time: TimeInterval
}

// What a scrubber position shows: a historical commit (rendered with
// `git show <sha>:<path>`) or the working tree (the on-disk file, rightmost).
enum TimeTravelStop: Equatable {
    case commit(TimeTravelRevision)
    case workingTree

    var isWorkingTree: Bool { if case .workingTree = self { return true }; return false }
    var sha: String? { if case .commit(let rev) = self { return rev.sha }; return nil }
}

// The scrubber's model: the file's commits plus the working-tree stop, ordered
// left → right as oldest → newest with the working tree pinned at the far right
// (one step past HEAD, per the phase's "far-right is the working tree, HEAD one
// step in"). `revisions` arrive newest-first, exactly as `git log --follow` /
// GitFileHistory yields them.
struct TimeTravelTimeline {
    let revisions: [TimeTravelRevision]  // index 0 = newest (HEAD-most)

    init(revisions: [TimeTravelRevision]) { self.revisions = revisions }

    var isEmpty: Bool { revisions.isEmpty }

    // Every commit is a stop, plus the working tree — so a tracked file with N
    // commits has N+1 stops.
    var stopCount: Int { revisions.count + 1 }

    // The rightmost position (the working tree) — where entering time-travel
    // starts so the view doesn't jump.
    var workingTreePosition: Int { revisions.count }

    // The stop at a position (0 ..< stopCount), left→right oldest→newest→working
    // tree; out-of-range positions clamp to the ends.
    func stop(at position: Int) -> TimeTravelStop {
        let p = clamp(position)
        if p == workingTreePosition { return .workingTree }
        // position 0 → oldest (revisions.last); position n-1 → newest (revisions.first).
        return .commit(revisions[revisions.count - 1 - p])
    }

    // The older revision this position diffs against (its immediate left
    // neighbour, which is always a commit). nil at the leftmost/oldest commit —
    // there is nothing older to compare against.
    func olderNeighbour(at position: Int) -> TimeTravelRevision? {
        let p = clamp(position)
        guard p > 0 else { return nil }
        if case .commit(let rev) = stop(at: p - 1) { return rev }
        return nil
    }

    private func clamp(_ p: Int) -> Int { min(max(0, p), stopCount - 1) }
}

// The git argv (after `git -C <root>`) each scrubber action needs. Paths are
// repo-relative — the app strips the root prefix before calling, since
// `git show <sha>:<path>` addresses the tree from the repo root.
enum TimeTravelGit {
    // Renders a stop's content on stdout. The working tree has no git command
    // (the app reads the file straight off disk), so it returns nil there.
    static func showArguments(stop: TimeTravelStop, relativePath: String) -> [String]? {
        switch stop {
        case .workingTree: return nil
        case .commit(let rev): return ["show", "\(rev.sha):\(relativePath)"]
        }
    }

    // Diffs a stop against its older neighbour (the +side is this stop's changed
    // lines). Working tree vs its neighbour (HEAD) compares the on-disk file to
    // that commit; a commit vs its neighbour compares the two trees. nil at the
    // leftmost commit — no older neighbour means no diff-to-neighbour marks.
    // `-U0` keeps only the @@ headers we parse.
    static func diffArguments(stop: TimeTravelStop, older: TimeTravelRevision?, relativePath: String) -> [String]? {
        guard let older else { return nil }
        switch stop {
        case .workingTree:
            return ["diff", older.sha, "-U0", "--", relativePath]
        case .commit(let rev):
            return ["diff", older.sha, rev.sha, "-U0", "--", relativePath]
        }
    }
}

// Parses the new-side (+) line numbers changed in a unified diff from its @@
// hunk headers — the shared parser behind both the diff-to-neighbour gutter
// marks here and Phase 5's GitChangedLines. A pure 0-count deletion still marks
// its anchor line so the removal site stays findable.
enum TimeTravelDiff {
    static func changedNewLines(inDiff diff: String) -> IndexSet {
        var lines = IndexSet()
        diff.enumerateLines { raw, _ in
            guard raw.hasPrefix("@@") else { return }
            let parts = raw.split(separator: " ")
            guard parts.count >= 3, parts[2].hasPrefix("+") else { return }
            let plus = parts[2].dropFirst().split(separator: ",")
            guard let start = Int(plus.first ?? "") else { return }
            let count = plus.count > 1 ? (Int(plus[1]) ?? 1) : 1
            if count == 0 {
                lines.insert(max(1, start))
            } else {
                lines.insert(integersIn: start..<(start + count))
            }
        }
        return lines
    }
}

// The header text shown above the slider for the current stop: sha · subject ·
// age for a commit, a plain label for the working tree. `now` is injected so
// the age is deterministic under test.
enum TimeTravelHeader {
    static func label(for stop: TimeTravelStop, now: TimeInterval) -> String {
        switch stop {
        case .workingTree:
            return "Working tree · uncommitted"
        case .commit(let rev):
            let age = relativeAge(from: rev.time, now: now)
            let subject = rev.subject.isEmpty ? "(no message)" : rev.subject
            return age.isEmpty ? "\(rev.shortSha) · \(subject)" : "\(rev.shortSha) · \(subject) · \(age)"
        }
    }

    // Compact "today" / "3d" / "5mo" / "2y", matching the file-history rows'
    // style (GitRowViews.relativeAge) but with an injectable `now`.
    static func relativeAge(from time: TimeInterval, now: TimeInterval) -> String {
        guard time > 0 else { return "" }
        let seconds = max(0, now - time)
        let days = Int(seconds / 86_400)
        if days <= 0 { return "today" }
        if days < 31 { return "\(days)d" }
        if days < 365 { return "\(days / 30)mo" }
        return "\(days / 365)y"
    }
}
