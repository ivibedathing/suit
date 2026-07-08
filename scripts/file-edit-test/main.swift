import Foundation

// Standalone assertion driver for the file-edit core (ROADMAP Phase 37),
// compiled against swift/Sources/suit/FileEdit.swift (Foundation-only) by
// scripts/file-edit-test.sh. Mirrors the Recipes / FeedbackRouting standalone-
// test pattern: no app, no UI — the dirty-flag transitions, the save/load
// baseline resets, the external-change reconciliation decision, and the atomic
// writer's round-trip.

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok: \(message)")
    } else {
        print("  FAIL: \(message)")
        failures += 1
    }
}

// MARK: - dirty transitions

print("== FileEditState.edited ==")
var state = FileEditState(savedText: "hello")
check(!state.isDirty, "a freshly loaded buffer is clean")
check(state.edited(to: "hello!") == true, "first divergence flips dirty on (returns true)")
check(state.isDirty, "buffer is now dirty")
check(state.edited(to: "hello!!") == false, "a further edit while already dirty does not flip")
check(state.isDirty, "buffer stays dirty")
check(state.edited(to: "hello") == true, "editing back to the saved content flips dirty off")
check(!state.isDirty, "buffer is clean again after reverting")

// MARK: - save / load reset the baseline

print("== markSaved / markLoaded ==")
var s2 = FileEditState(savedText: "a")
s2.edited(to: "a+b")
check(s2.isDirty, "edited buffer is dirty before save")
s2.markSaved("a+b")
check(!s2.isDirty, "markSaved clears dirty")
check(s2.edited(to: "a+b") == false, "no divergence from the new saved baseline")
check(s2.edited(to: "a+b+c") == true, "editing past the saved baseline goes dirty again")
s2.markLoaded("fresh")
check(!s2.isDirty, "markLoaded resets clean")
check(s2.edited(to: "fresh") == false, "buffer matching the reloaded content is clean")

// MARK: - external-change reconciliation

print("== resolveExternalChange ==")
var clean = FileEditState(savedText: "x")
check(clean.resolveExternalChange(diskText: "x", bufferText: "x") == .ignore,
      "disk == buffer → ignore (our own save echoing back)")
check(clean.resolveExternalChange(diskText: "y", bufferText: "x") == .reload,
      "clean buffer, disk changed → reload silently")

var dirty = FileEditState(savedText: "x")
dirty.edited(to: "x-local")
check(dirty.resolveExternalChange(diskText: "x-remote", bufferText: "x-local") == .warn,
      "dirty buffer, disk changed → warn before clobbering")
check(dirty.resolveExternalChange(diskText: "x-local", bufferText: "x-local") == .ignore,
      "dirty buffer whose disk already matches (we just saved) → ignore")

// MARK: - atomic writer round-trip

print("== FileEditWriter.write ==")
let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("suit-file-edit-test-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let target = tmp.appendingPathComponent("out.swift").path

let payload = "let x = 1\n// π über\nfunc f() {}\n"
do {
    try FileEditWriter.write(payload, toPath: target)
    let readBack = try String(contentsOfFile: target, encoding: .utf8)
    check(readBack == payload, "written bytes round-trip exactly (UTF-8, multi-byte intact)")
    // Overwrite atomically with different-length content — no residue from the longer prior write.
    try FileEditWriter.write("tiny", toPath: target)
    let readBack2 = try String(contentsOfFile: target, encoding: .utf8)
    check(readBack2 == "tiny", "atomic overwrite replaces content with no truncation residue")
} catch {
    check(false, "FileEditWriter.write threw: \(error)")
}

// MARK: - summary

print("")
if failures == 0 {
    print("ALL PASSED")
    exit(0)
} else {
    print("\(failures) ASSERTION(S) FAILED")
    exit(1)
}
