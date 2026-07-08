import Foundation

// Standalone assertions for the Phase 38 activity-feed core (Activity.swift).
// Compiled against that one Foundation-only file by scripts/activity-test.sh —
// no app, no UI. Mirrors the RoadmapParser / FeedbackRouting / Recipes /
// FileEdit harness pattern.

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if condition {
        print("ok   - \(message)")
    } else {
        print("FAIL - \(message)")
        failures += 1
    }
}

// A fixed calendar so day boundaries are deterministic regardless of the host
// timezone.
var cal = Calendar(identifier: .gregorian)
cal.timeZone = TimeZone(identifier: "UTC")!

// Day anchors (UTC midnights).
let day2: TimeInterval = 1_700_000_000            // some instant
let day2Start = cal.startOfDay(for: Date(timeIntervalSince1970: day2)).timeIntervalSince1970
let day1Start = day2Start - 86_400
let day3Start = day2Start + 86_400

func event(_ id: String, _ kind: ActivityKind, at t: TimeInterval,
           title: String = "t", repo: String? = nil, session: String? = nil,
           pr: Int? = nil, prURL: String? = nil) -> ActivityEvent {
    ActivityEvent(id: id, kind: kind, timestamp: t, title: title, repo: repo,
                  sessionId: session, prNumber: pr, prURL: prURL)
}

// Rows across kinds and days.
let events = [
    event("s1", .sessionDone,       at: day1Start + 100, title: "Fix login",  repo: "suit", session: "sess-A"),
    event("s2", .sessionNeedsInput, at: day2Start + 50,  title: "Need review", repo: "suit", session: "sess-B"),
    event("p1", .prMerged,          at: day2Start + 200, title: "Merge #12",  repo: "suit", pr: 12, prURL: "https://gh/pr/12"),
    event("c1", .ciFail,            at: day2Start + 300, title: "CI red",     repo: "other", session: "sess-C"),
    event("a1", .autopilotMerged,   at: day2Start + 400, title: "Phase 5",   repo: "suit", pr: 20, prURL: "https://gh/pr/20"),
    event("a2", .autopilotBlocked,  at: day2Start + 500, title: "Preflight", repo: "suit"),
    event("s3", .sessionDone,       at: day3Start + 10,  title: "Tomorrow",  repo: "suit", session: "sess-A"),
]

// MARK: - Ordering (newest-first)

let ordered = ActivityFeed.ordered(events)
check(ordered.first?.id == "s3", "ordered: newest row (s3) first")
check(ordered.last?.id == "s1", "ordered: oldest row (s1) last")
let timestamps = ordered.map { $0.timestamp }
check(timestamps == timestamps.sorted(by: >), "ordered: strictly newest-first")

// Tie-break: two equal-timestamp rows keep input order reversed & deterministic.
let tie = [
    event("first",  .sessionDone, at: 1000),
    event("second", .sessionDone, at: 1000),
]
check(ActivityFeed.ordered(tie).map { $0.id } == ["second", "first"], "ordered: ties are deterministic (later input first)")

// MARK: - Routing

check(event("x", .sessionDone, at: 0, session: "sess-A").route == .session("sess-A"), "route: session id wins")
check(event("x", .prMerged, at: 0, prURL: "https://gh/pr/12").route == .pr("https://gh/pr/12"), "route: PR url when no session")
check(event("x", .autopilotBlocked, at: 0).route == .autopilotLog, "route: autopilot row → log")
check(event("x", .prOpened, at: 0).route == .none, "route: nothing routable → none")
// A session id takes precedence over a PR url on the same row.
check(event("x", .ciFail, at: 0, session: "s", prURL: "u").route == .session("s"), "route: session beats PR url")

// MARK: - Filtering

check(ActivityFeed.filter(events, repo: "suit").count == 6, "filter: by repo")
check(ActivityFeed.filter(events, sessionId: "sess-A").count == 2, "filter: by session")
check(ActivityFeed.filter(events, kind: .sessionDone).count == 2, "filter: by kind")
check(ActivityFeed.filter(events, repo: "suit", kind: .prMerged).count == 1, "filter: combined repo + kind")
check(ActivityFeed.repos(in: events) == ["other", "suit"], "filter: distinct repos sorted")
check(ActivityFeed.kinds(in: events).first == .sessionDone, "filter: kinds in declaration order")

// MARK: - Daily digest

let digest = DailyDigest.rollup(events: events, day: Date(timeIntervalSince1970: day2Start + 60), calendar: cal)
check(digest.sessionsFinished == 0, "digest day2: no session-done rows that day")
check(digest.prsMerged == 1, "digest day2: one PR merged")
check(digest.ciFailures == 1, "digest day2: one CI failure")
check(digest.autopilotMerged == 1, "digest day2: one autopilot merge")
check(digest.total == 3, "digest day2: total rolls up notable counts")
check(!digest.highlights.isEmpty && digest.highlights.count <= 5, "digest day2: highlights present, capped")
// Highlights are newest-first among notable rows: autopilotBlocked(500) then autopilotMerged(400) then ciFail(300) then prMerged(200).
check(digest.highlights.first == "Autopilot blocked: Preflight", "digest day2: highlights newest-first")

let digest1 = DailyDigest.rollup(events: events, day: Date(timeIntervalSince1970: day1Start + 60), calendar: cal)
check(digest1.sessionsFinished == 1 && digest1.total == 1, "digest day1: only that day's session-done counted")

let digest3 = DailyDigest.rollup(events: events, day: Date(timeIntervalSince1970: day3Start + 60), calendar: cal)
check(digest3.sessionsFinished == 1, "digest day3: rolls up only day3")

let empty = DailyDigest.rollup(events: events, day: Date(timeIntervalSince1970: day2Start - 5 * 86_400), calendar: cal)
check(empty.isEmpty && empty.summary == "No activity today.", "digest: empty day summarizes as no activity")

// MARK: - Store: append, dedup, round-trip, ordering across a reload

let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("activity-test-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.removeItem(at: tmpDir)
let storeFile = tmpDir.appendingPathComponent("activity.jsonl")

do {
    let store = ActivityStore(fileURL: storeFile)
    check(store.events.isEmpty, "store: starts empty")
    check(store.record(events[0]), "store: first record appends")
    check(!store.record(events[0]), "store: duplicate id is skipped")
    for e in events.dropFirst() { store.record(e) }
    check(store.events.count == events.count, "store: all distinct rows persisted")
}

// A fresh store over the same file reloads every row and re-dedups.
do {
    let reloaded = ActivityStore(fileURL: storeFile)
    check(reloaded.events.count == events.count, "store: reload reads back all rows")
    check(ActivityFeed.ordered(reloaded.events).first?.id == "s3", "store: reloaded rows still order newest-first")
    check(!reloaded.record(events[2]), "store: reload keeps known ids (dedup survives restart)")
}
try? FileManager.default.removeItem(at: tmpDir)

// MARK: - Result

if failures == 0 {
    print("\nAll activity-feed assertions passed.")
    exit(0)
} else {
    print("\n\(failures) assertion(s) failed.")
    exit(1)
}
