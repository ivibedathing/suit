import Foundation

// Standalone harness for FileWatch.swift — the decisions behind live file
// watching (FileWatchPolicy) and the change stamp (FileStamp). Compiled by
// scripts/file-watch-test.sh against the Foundation-only source; no app or UI
// dependencies, no run loop.

var failures = 0

func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok   \(message)")
    } else {
        print("  FAIL \(message)")
        failures += 1
    }
}

print("== event classification ==")

check(FileWatchPolicy.action(for: [.write]) == .reread,
      "a plain write re-reads without re-opening")
check(FileWatchPolicy.action(for: [.extend]) == .reread,
      "an append re-reads without re-opening")
check(FileWatchPolicy.action(for: [.write, .extend]) == .reread,
      "write+extend together still just re-reads")
check(FileWatchPolicy.action(for: [.rename]) == .rearm,
      "a rename (the atomic-replace case) re-arms")
check(FileWatchPolicy.action(for: [.delete]) == .rearm,
      "an unlink re-arms")
check(FileWatchPolicy.action(for: [.revoke]) == .rearm,
      "a revoke re-arms")
// The regression this exists for: an atomic replace commonly reports write and
// rename in the same burst. Classifying that as a plain write keeps a dead
// descriptor and the watcher goes permanently deaf after one edit.
check(FileWatchPolicy.action(for: [.write, .rename]) == .rearm,
      "a mixed write+rename burst re-arms rather than trusting the dead fd")
check(FileWatchPolicy.action(for: [.write, .extend, .delete, .rename]) == .rearm,
      "replacement wins over write flags in any mixed burst")
check(FileWatchPolicy.action(for: []) == .reread,
      "an empty mask degrades to a re-read, never to going deaf")

print("== re-arm backoff ==")

check(FileWatchPolicy.rearmDelay(attempt: 0) != nil,
      "the first re-open attempt is scheduled")
let delays = (0..<FileWatchPolicy.rearmDelays.count).compactMap { FileWatchPolicy.rearmDelay(attempt: $0) }
check(delays.count == FileWatchPolicy.rearmDelays.count,
      "every configured attempt yields a delay")
check(zip(delays, delays.dropFirst()).allSatisfy { $0 < $1 },
      "the backoff strictly increases")
check(delays.first.map { $0 < 0.05 } ?? false,
      "the first retry is fast enough to catch a mid-replace absent path")
check(FileWatchPolicy.rearmDelay(attempt: FileWatchPolicy.rearmDelays.count) == nil,
      "the backoff runs out rather than retrying forever")
check(FileWatchPolicy.rearmDelay(attempt: -1) == nil,
      "a negative attempt gives up instead of trapping on the index")
check(FileWatchPolicy.coalesceInterval > 0 && FileWatchPolicy.coalesceInterval < 1,
      "the coalesce window is sub-second but non-zero")

print("== stamp comparison ==")

let base = Date(timeIntervalSince1970: 1_700_000_000)
let a = FileStamp(modificationDate: base, size: 10, inode: 1)

check(!FileStamp.changed(from: a, to: a), "an identical stamp is not a change")
check(FileStamp.changed(from: a, to: FileStamp(modificationDate: base.addingTimeInterval(1), size: 10, inode: 1)),
      "a newer mtime is a change")
check(FileStamp.changed(from: a, to: FileStamp(modificationDate: base, size: 11, inode: 1)),
      "a different size is a change even at the same mtime")
// An atomic replace can land inside the same mtime second with the same byte
// count (a one-character swap); the inode is the only thing that differs.
check(FileStamp.changed(from: a, to: FileStamp(modificationDate: base, size: 10, inode: 2)),
      "a new inode at the same mtime and size is a change")
check(FileStamp.changed(from: nil, to: a),
      "a first-ever stamp counts as changed")
check(!FileStamp.changed(from: a, to: nil),
      "a file that vanished is not a change — the pane keeps its last good content")
check(!FileStamp.changed(from: nil, to: nil),
      "nothing to compare is not a change")

print("== stamp from disk ==")

let dir = (NSTemporaryDirectory() as NSString)
    .appendingPathComponent("file-watch-test-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(atPath: dir) }

let path = (dir as NSString).appendingPathComponent("watched.txt")
check(FileStamp(path: path) == nil, "a missing path has no stamp")

try? Data("hello".utf8).write(to: URL(fileURLWithPath: path))
let first = FileStamp(path: path)
check(first != nil, "an existing path stamps")
check(first?.size == 5, "the stamp reports the byte count")
check((first?.inode ?? 0) != 0, "the stamp carries a real inode")
check(!FileStamp.changed(from: first, to: FileStamp(path: path)),
      "re-stamping an untouched file reports no change")

// The atomic write the app itself uses (FileEditWriter / Data.write(.atomic)):
// same path, same length, brand-new inode. Without the inode in the stamp this
// is exactly the change a same-second rewrite would hide.
try? Data("world".utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
let second = FileStamp(path: path)
check(FileStamp.changed(from: first, to: second),
      "an atomic same-length rewrite is detected")

if failures == 0 {
    print("\nALL PASSED")
} else {
    print("\n\(failures) FAILURE(S)")
    exit(1)
}
