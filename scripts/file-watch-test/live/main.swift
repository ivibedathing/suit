import Foundation

// The other half of the file-watch harness: FileWatcher against a real run loop
// and a real file, because the failures this feature exists to prevent are all
// in the descriptor lifecycle and none of them are visible to a pure test.
//
// FileWatcher is Foundation-only (Dispatch + RunLoop, no AppKit), so it compiles
// standalone the same way the pure core does. Each scenario writes the file the
// way something in the real world writes it, pumps the run loop, and asserts on
// the content the callback saw.
//
// The waits are wall-clock, so they're set well past FileWatchPolicy's coalesce
// window and re-arm backoff rather than exactly at them.

var failures = 0

func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok   \(message)")
    } else {
        print("  FAIL \(message)")
        failures += 1
    }
}

let dir = (NSTemporaryDirectory() as NSString)
    .appendingPathComponent("file-watch-live-\(ProcessInfo.processInfo.processIdentifier)")
try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
let path = (dir as NSString).appendingPathComponent("watched.txt")
let url = URL(fileURLWithPath: path)

func write(_ text: String, atomic: Bool = true) {
    try! Data(text.utf8).write(to: url, options: atomic ? [.atomic] : [])
}

// What the callback saw on disk each time it fired. "<gone>" records a callback
// that arrived while the file was absent — the panes filter those out (a nil
// FileStamp / unreadable text is not a change), so seeing one here is fine.
var seen: [String] = []

write("v0")
let watcher = FileWatcher(path: path) {
    seen.append((try? String(contentsOfFile: path, encoding: .utf8)) ?? "<gone>")
}

func pump(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}
pump(0.2)

print("== atomic replace ==")

// Data.write(.atomic) is what FileEditWriter, git and most editors do: write a
// temp file, rename it over the target. The descriptor we hold now points at an
// unlinked inode.
write("v1")
pump(0.5)
check(seen.contains("v1"), "an atomic replace is reported")

// The regression that motivates the whole re-arm path: a watcher that treats
// rename as an ordinary write keeps the dead descriptor and never fires again,
// so it looks correct until the *second* edit.
write("v2")
pump(0.5)
check(seen.contains("v2"), "a second atomic replace is reported (the fd was re-armed)")

print("== write in place ==")

let handle = FileHandle(forWritingAtPath: path)!
try! handle.seek(toOffset: 0)
handle.write(Data("v3".utf8))
try! handle.close()
pump(0.5)
check(seen.contains("v3"), "a same-inode write is reported")

print("== burst coalescing ==")

let before = seen.count
for index in 0..<5 { write("burst\(index)") }
pump(0.6)
let callbacks = seen.count - before
check(callbacks >= 1, "a five-write burst is reported")
check(callbacks <= 2, "a five-write burst coalesces (\(callbacks) callback(s), not 5)")
check(seen.last == "burst4", "the burst's final content is what the callback reads")

print("== delete and recreate ==")

// A branch switch, or a build that regenerates its output: the file disappears
// and comes back. Nothing is watching while it's absent, so the successful
// re-open has to report the change itself or the pane stays stale forever.
try! FileManager.default.removeItem(atPath: path)
pump(0.3)
write("v5", atomic: false)
pump(1.0)
check(seen.contains("v5"), "a file that vanished and came back is reported")

print("== stop ==")

watcher.stop()
let afterStop = seen.count
write("v6")
pump(0.5)
check(seen.count == afterStop, "a stopped watcher reports nothing further")

try? FileManager.default.removeItem(atPath: dir)

if failures == 0 {
    print("\nALL PASSED")
} else {
    print("\n\(failures) FAILURE(S)")
    exit(1)
}
