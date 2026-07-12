import Foundation

// Standalone assertion driver for StoreFile (swift/Sources/suit/StoreFile.swift,
// Foundation-only, no app deps), compiled and run by scripts/storefile-test.sh.
// Mirrors the RoadmapParser / DiffParser / Recipes standalone-test pattern.
//
// StoreFile is the shared load helper for the ~/.suit JSON stores. The bug it
// fixes: the stores used to load with `try?` and start empty on *any* failure,
// so a present-but-unreadable file was silently overwritten (wiped) by the next
// atomic save. These assertions pin the three behaviours that prevent that:
//   • a valid file decodes and is left in place,
//   • a present-but-corrupt file is quarantined (bytes preserved), not wiped,
//   • an absent file is a clean empty start with no artifact left behind.

struct Item: Codable, Equatable { let id: Int }

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok: \(message)")
    } else {
        print("  FAIL: \(message)")
        failures += 1
    }
}

let fm = FileManager.default
let dir = NSTemporaryDirectory() + "storefile-test-\(getpid())"
try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
defer { try? fm.removeItem(atPath: dir) }

// MARK: - valid file decodes and is left untouched

print("== StoreFile.load — valid file ==")
let good = dir + "/good.json"
try! JSONEncoder().encode([Item(id: 1), Item(id: 2)]).write(to: URL(fileURLWithPath: good))
check(StoreFile.load([Item].self, from: good) == [Item(id: 1), Item(id: 2)],
      "a valid file decodes to its model")
check(fm.fileExists(atPath: good), "a valid file is left in place")

// MARK: - corrupt file is quarantined, never wiped

print("== StoreFile.load — present but corrupt ==")
let bad = dir + "/bad.json"
let badBytes = "{ not json at all"
try! Data(badBytes.utf8).write(to: URL(fileURLWithPath: bad))
check(StoreFile.load([Item].self, from: bad) == nil,
      "a corrupt file returns nil (caller starts empty)")
check(!fm.fileExists(atPath: bad),
      "the corrupt original is moved aside, not overwritten in place")
let quarantined = (try! fm.contentsOfDirectory(atPath: dir)).filter { $0.hasPrefix("bad.json.corrupt-") }
check(quarantined.count == 1, "the corrupt file is quarantined to bad.json.corrupt-<epoch>")
if let q = quarantined.first {
    check((try! String(contentsOfFile: dir + "/" + q, encoding: .utf8)) == badBytes,
          "the quarantined file preserves the original bytes (no data loss)")
}

// MARK: - absent file is a clean empty start

print("== StoreFile.load — absent file ==")
let missing = dir + "/missing.json"
check(StoreFile.load([Item].self, from: missing) == nil, "an absent file returns nil")
check((try! fm.contentsOfDirectory(atPath: dir)).allSatisfy { !$0.contains("missing") },
      "an absent file leaves no artifact behind (no spurious quarantine)")

// MARK: - summary

print("")
if failures == 0 {
    print("ALL PASSED")
    exit(0)
} else {
    print("\(failures) FAILED")
    exit(1)
}
