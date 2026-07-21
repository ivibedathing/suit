import Foundation

// Asserts FileIndex.fallbackScan — the non-git-repo scan behind the Files
// sidebar and Cmd-P. The regression it guards: the walk used
// .skipsHiddenFiles, so dot-directories (.claude, .github, .config) were
// invisible outside a git repo while `git ls-files` happily reported them
// inside one. Hidden content is now indexed; only the known-noisy trees and
// Finder droppings are pruned.

var failures = 0

func check(_ condition: Bool, _ message: String) {
    if condition {
        print("ok   \(message)")
    } else {
        print("FAIL \(message)")
        failures += 1
    }
}

let root = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("file-index-test-\(ProcessInfo.processInfo.processIdentifier)")
let fm = FileManager.default
try? fm.removeItem(at: root)

func write(_ relativePath: String) {
    let url = root.appendingPathComponent(relativePath)
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    fm.createFile(atPath: url.path, contents: Data("x".utf8))
}

write("README.md")
write("src/main.swift")
write(".claude/agents/advisor.md")
write(".github/workflows/ci.yml")
write(".gitignore")
write(".DS_Store")
write("._resourcefork")
write(".git/objects/ab/cdef")
write("node_modules/left-pad/index.js")
write(".Trash/deleted.txt")

let scanned = FileIndex.fallbackScan(root: root.path)
let files = Set(scanned)

check(files.contains("README.md"), "plain file indexed")
check(files.contains("src/main.swift"), "nested plain file indexed")
check(files.contains(".claude/agents/advisor.md"), "hidden directory's contents indexed")
check(files.contains(".github/workflows/ci.yml"), "second hidden directory indexed")
check(files.contains(".gitignore"), "dotfile at the root indexed")

check(!files.contains(".DS_Store"), ".DS_Store pruned")
check(!files.contains("._resourcefork"), "AppleDouble file pruned")
check(!scanned.contains { $0.hasPrefix(".git/") }, ".git tree pruned")
check(!scanned.contains { $0.hasPrefix("node_modules/") }, "node_modules pruned")
check(!scanned.contains { $0.hasPrefix(".Trash/") }, ".Trash pruned")

check(scanned == scanned.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending },
      "results are case-insensitively sorted")

try? fm.removeItem(at: root)

if failures == 0 {
    print("\nAll FileIndex assertions passed.")
    exit(0)
}
print("\n\(failures) assertion(s) failed.")
exit(1)
