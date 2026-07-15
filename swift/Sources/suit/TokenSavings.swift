import Foundation

// Token-savings ledger — the pure, UI-free, standalone-compilable core (the
// RoadmapParser / Recipes / FeedbackRouting pattern; verified by
// scripts/token-savings-test.sh). Suit's token filters (the rtk PreToolUse
// rewrite and the post-tool compress/dedup filter) append one JSONL line per
// rewrite to ~/.suit/token-savings.jsonl recording the counterfactual they saw:
//   {ts, session_id, tool, kind: compress|dedup, original_chars, emitted_chars}
// This file reads that ledger back for the app: an incremental tail (only
// appended bytes are parsed on each refresh) aggregated into per-session
// totals, plus the chars/4 token estimate and the compact-count formatting the
// title-bar counter displays. scripts/token-savings-report.sh is the CLI view
// over the same file; the estimate here matches its `est_tokens`.
enum TokenSavings {

    struct Totals: Equatable {
        var rewrites = 0
        var compressRewrites = 0
        var dedupRewrites = 0
        var originalChars = 0
        var emittedChars = 0

        var savedChars: Int { max(0, originalChars - emittedChars) }
        // chars/4 estimate, matching scripts/token-savings-report.sh
        // (the meter keeps counts, not text, so exact tokenization is gone).
        var estSavedTokens: Int { (savedChars + 2) / 4 }
    }

    // "873" / "1.2k" / "12k" / "999k" / "1.2M" — the title-bar counter format.
    static func compactCount(_ n: Int) -> String {
        guard n >= 1000 else { return "\(n)" }
        let k = Double(n) / 1000
        if k < 10 { return String(format: "%.1fk", k) }
        let kr = Int(k.rounded())
        guard kr >= 1000 else { return "\(kr)k" }
        return String(format: "%.1fM", k / 1000)
    }

    // The counter's hover text: the estimate spelled out with its breakdown.
    static func tooltip(for totals: Totals) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let tokens = formatter.string(from: NSNumber(value: totals.estSavedTokens)) ?? "\(totals.estSavedTokens)"
        var kinds: [String] = []
        if totals.compressRewrites > 0 { kinds.append("\(totals.compressRewrites) elided") }
        if totals.dedupRewrites > 0 { kinds.append("\(totals.dedupRewrites) read-dedup") }
        let breakdown = kinds.isEmpty ? "" : " (\(kinds.joined(separator: ", ")))"
        let plural = totals.rewrites == 1 ? "" : "s"
        return "Suit's token filters saved ≈\(tokens) tokens in this session — "
            + "\(totals.rewrites) result rewrite\(plural)\(breakdown). Estimate: saved chars ÷ 4."
    }
}

// Incremental reader over the savings JSONL: remembers the byte offset it has
// consumed so each refresh stats the file and parses only what was appended.
// A shrunken file (rotation / hand truncation) resets and re-reads from the
// top; torn or non-JSON lines are skipped, and a trailing partial line is
// buffered until its remainder arrives. Foundation-only so the harness can
// exercise it against scratch files.
final class TokenSavingsLedger {
    private(set) var bySession: [String: TokenSavings.Totals] = [:]
    private var offset: UInt64 = 0
    private var remainder = ""

    func totals(forSessionId id: String) -> TokenSavings.Totals? {
        bySession[id]
    }

    func reset() {
        bySession = [:]
        offset = 0
        remainder = ""
    }

    // Re-stat + read appended bytes. Returns whether any state changed.
    @discardableResult
    func refresh(path: String) -> Bool {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value else {
            // File gone: a fresh one may appear later — start over then.
            guard offset > 0 || !bySession.isEmpty else { return false }
            reset()
            return true
        }
        var changed = false
        if size < offset {
            reset()
            changed = true
        }
        guard size > offset, let handle = FileHandle(forReadingAtPath: path) else { return changed }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty else { return changed }
        offset += UInt64(data.count)
        return ingest(String(decoding: data, as: UTF8.self)) || changed
    }

    // Parse a chunk of appended text; lines may arrive split across chunks.
    // Returns whether any row landed in the totals.
    @discardableResult
    func ingest(_ chunk: String) -> Bool {
        var text = remainder + chunk
        // Hold back a trailing partial line for the next chunk.
        if let lastNewline = text.lastIndex(of: "\n") {
            remainder = String(text[text.index(after: lastNewline)...])
            text = String(text[..<lastNewline])
        } else {
            remainder = text
            return false
        }

        var changed = false
        for line in text.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let sessionId = object["session_id"] as? String else { continue }
            var totals = bySession[sessionId] ?? TokenSavings.Totals()
            totals.rewrites += 1
            switch object["kind"] as? String {
            case "compress": totals.compressRewrites += 1
            case "dedup": totals.dedupRewrites += 1
            default: break
            }
            totals.originalChars += (object["original_chars"] as? NSNumber)?.intValue ?? 0
            totals.emittedChars += (object["emitted_chars"] as? NSNumber)?.intValue ?? 0
            bySession[sessionId] = totals
            changed = true
        }
        return changed
    }
}

// App-side singleton: the ledger tailing the real ~/.suit/token-savings.jsonl.
// Queried from pane chrome refreshes (which ClaudeSessionMonitor.didUpdate
// drives continuously while any session works), so a light time throttle
// stands in for a file watcher. $HOME-resolved like the other ~/.suit stores
// so a sandboxed harness run never reads the user's real ledger.
final class TokenSavingsMonitor {
    static let shared = TokenSavingsMonitor()

    private let ledger = TokenSavingsLedger()
    private var lastRefresh = Date.distantPast
    private static let refreshInterval: TimeInterval = 1.0

    private static var path: String {
        (ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory())
            + "/.suit/token-savings.jsonl"
    }

    // Main-thread only (called from chrome refreshes).
    func totals(forSessionId id: String) -> TokenSavings.Totals? {
        let now = Date()
        if now.timeIntervalSince(lastRefresh) >= Self.refreshInterval {
            lastRefresh = now
            ledger.refresh(path: Self.path)
        }
        return ledger.totals(forSessionId: id)
    }
}
