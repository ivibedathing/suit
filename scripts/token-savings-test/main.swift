import Foundation

// Standalone assertion driver for the token-savings ledger core, compiled
// against swift/Sources/suit/TokenSavings.swift (Foundation-only) by
// scripts/token-savings-test.sh. Mirrors the BudgetGuardrails / FeedbackRouting
// standalone-test pattern: no app, no UI. Asserts the JSONL aggregation the
// title-bar counter rests on — per-session totals, the chars/4 estimate,
// torn-line tolerance, chunk-split lines, the incremental file tail, the
// truncation reset, and the compact-count formatting.

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok: \(message)")
    } else {
        print("  FAIL: \(message)")
        failures += 1
    }
}

func row(_ session: String, kind: String, orig: Int, emit: Int) -> String {
    "{\"ts\":1720000000,\"session_id\":\"\(session)\",\"tool\":\"Read\",\"kind\":\"\(kind)\",\"original_chars\":\(orig),\"emitted_chars\":\(emit)}\n"
}

// MARK: - Aggregation

print("== per-session aggregation ==")
do {
    let ledger = TokenSavingsLedger()
    ledger.ingest(row("s1", kind: "compress", orig: 50_000, emit: 24_000)
                  + row("s1", kind: "dedup", orig: 10_000, emit: 200)
                  + row("s2", kind: "compress", orig: 40_000, emit: 30_000))
    let s1 = ledger.totals(forSessionId: "s1")
    check(s1?.rewrites == 2, "s1 counts both rewrites")
    check(s1?.compressRewrites == 1 && s1?.dedupRewrites == 1, "s1 splits rewrites by kind")
    check(s1?.savedChars == 35_800, "s1 saved chars sum across rows")
    check(s1?.estSavedTokens == (35_800 + 2) / 4, "token estimate matches the report script's chars/4")
    check(ledger.totals(forSessionId: "s2")?.savedChars == 10_000, "s2 aggregates separately")
    check(ledger.totals(forSessionId: "s3") == nil, "an unseen session has no totals")
}

print("== malformed rows ==")
do {
    let ledger = TokenSavingsLedger()
    ledger.ingest("not json at all\n{\"session_id\":42}\n{\"kind\":\"compress\"}\n"
                  + row("s1", kind: "compress", orig: 8, emit: 4))
    check(ledger.totals(forSessionId: "s1")?.rewrites == 1, "garbage lines are skipped, valid rows land")
    let t = ledger.totals(forSessionId: "s1")
    check(t?.savedChars == 4 && t?.estSavedTokens == 1, "tiny row estimates round sanely")
}

do {
    let ledger = TokenSavingsLedger()
    ledger.ingest(row("s1", kind: "weird", orig: 100, emit: 0))
    let t = ledger.totals(forSessionId: "s1")
    check(t?.rewrites == 1 && t?.compressRewrites == 0 && t?.dedupRewrites == 0,
          "an unknown kind still counts as a rewrite")
    // A row claiming to emit more than the original never shows negative savings.
    ledger.ingest(row("s4", kind: "compress", orig: 10, emit: 50))
    check(ledger.totals(forSessionId: "s4")?.savedChars == 0, "emit > orig clamps saved chars at 0")
}

print("== chunk-split lines ==")
do {
    let ledger = TokenSavingsLedger()
    let line = row("s1", kind: "dedup", orig: 1_000, emit: 100)
    let cut = line.index(line.startIndex, offsetBy: 25)
    ledger.ingest(String(line[..<cut]))
    check(ledger.totals(forSessionId: "s1") == nil, "a partial line is buffered, not parsed")
    ledger.ingest(String(line[cut...]))
    check(ledger.totals(forSessionId: "s1")?.rewrites == 1, "the remainder completes the buffered line")
}

// MARK: - Incremental file tail

print("== refresh(path:) ==")
do {
    let dir = NSTemporaryDirectory() + "/token-savings-test-\(getpid())"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/token-savings.jsonl"

    let ledger = TokenSavingsLedger()
    check(ledger.refresh(path: path) == false, "a missing file with no state is a quiet no-op")

    try? row("s1", kind: "compress", orig: 4_000, emit: 1_000)
        .write(toFile: path, atomically: true, encoding: .utf8)
    check(ledger.refresh(path: path) == true, "first refresh reads the file")
    check(ledger.totals(forSessionId: "s1")?.savedChars == 3_000, "first row lands")

    check(ledger.refresh(path: path) == false, "no appended bytes → no change")

    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(Data(row("s1", kind: "dedup", orig: 2_000, emit: 500).utf8))
        handle.closeFile()
    }
    check(ledger.refresh(path: path) == true, "an append is picked up")
    check(ledger.totals(forSessionId: "s1")?.savedChars == 4_500, "appended row adds to the totals")
    check(ledger.totals(forSessionId: "s1")?.rewrites == 2, "rewrite count follows")

    // Truncation / rotation: a smaller file resets and re-reads from the top.
    try? row("s9", kind: "compress", orig: 800, emit: 400)
        .write(toFile: path, atomically: true, encoding: .utf8)
    check(ledger.refresh(path: path) == true, "a shrunken file forces a reset")
    check(ledger.totals(forSessionId: "s1") == nil, "old sessions are gone after the reset")
    check(ledger.totals(forSessionId: "s9")?.savedChars == 400, "the rotated file's rows are read")

    // Deletion: state clears, and a later recreated file reads from scratch.
    try? FileManager.default.removeItem(atPath: path)
    check(ledger.refresh(path: path) == true, "a deleted file clears the ledger")
    check(ledger.totals(forSessionId: "s9") == nil, "no totals survive the delete")
    check(ledger.refresh(path: path) == false, "still-missing file stays a no-op")
}

// MARK: - Formatting

print("== compactCount ==")
check(TokenSavings.compactCount(0) == "0", "0 stays bare")
check(TokenSavings.compactCount(999) == "999", "sub-1000 stays bare")
check(TokenSavings.compactCount(1_000) == "1.0k", "1000 → 1.0k")
check(TokenSavings.compactCount(1_234) == "1.2k", "1234 → 1.2k")
check(TokenSavings.compactCount(12_345) == "12k", "12345 → 12k")
check(TokenSavings.compactCount(999_400) == "999k", "999400 → 999k")
check(TokenSavings.compactCount(1_200_000) == "1.2M", "1.2M formats")

print("== tooltip ==")
do {
    var totals = TokenSavings.Totals()
    totals.rewrites = 3
    totals.compressRewrites = 2
    totals.dedupRewrites = 1
    totals.originalChars = 50_000
    totals.emittedChars = 10_000
    let tip = TokenSavings.tooltip(for: totals)
    check(tip.contains("2 elided") && tip.contains("1 read-dedup"), "tooltip carries the kind breakdown")
    check(tip.contains("3 result rewrites"), "tooltip counts rewrites")

    var one = TokenSavings.Totals()
    one.rewrites = 1
    one.dedupRewrites = 1
    one.originalChars = 400
    one.emittedChars = 0
    check(TokenSavings.tooltip(for: one).contains("1 result rewrite ("), "singular rewrite reads right")
}

print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
