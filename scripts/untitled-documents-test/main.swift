import Foundation

// Assertions for UntitledDocuments — the ⌘N scratch-buffer naming.
// Compiled and run by scripts/untitled-documents-test.sh.

var failures = 0

func check(_ condition: Bool, _ label: String) {
    if condition {
        print("ok: \(label)")
    } else {
        print("FAIL: \(label)")
        failures += 1
    }
}

func equal<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    check(actual == expected, "\(label) (got \(actual), expected \(expected))")
}

// MARK: - nextName: the common path

equal(UntitledDocuments.nextName(takenNames: []), "Untitled-1",
      "an empty window starts at Untitled-1")
equal(UntitledDocuments.nextName(takenNames: ["Untitled-1"]), "Untitled-2",
      "a second scratch buffer takes the next index")
equal(UntitledDocuments.nextName(takenNames: ["Untitled-1", "Untitled-2", "Untitled-3"]), "Untitled-4",
      "three open scratch buffers push to 4")

// MARK: - nextName: freed slots come back

equal(UntitledDocuments.nextName(takenNames: ["Untitled-1", "Untitled-3"]), "Untitled-2",
      "the lowest free index wins over one-past-the-highest")
equal(UntitledDocuments.nextName(takenNames: ["Untitled-2", "Untitled-3"]), "Untitled-1",
      "closing the first buffer frees index 1")
equal(UntitledDocuments.nextName(takenNames: ["Untitled-9"]), "Untitled-1",
      "a high index alone does not reserve the ones below it")

// MARK: - nextName ignores everything that is not a scratch name

equal(UntitledDocuments.nextName(takenNames: ["README.md", "Terminal", "zsh"]), "Untitled-1",
      "ordinary tab titles reserve nothing")
equal(UntitledDocuments.nextName(takenNames: ["Untitled-1.txt", "Untitled-draft", "Untitled-"]), "Untitled-1",
      "real files that merely start with the prefix do not take a slot")
equal(UntitledDocuments.nextName(takenNames: ["untitled-1", "UNTITLED-1"]), "Untitled-1",
      "the prefix match is case-sensitive")

// The order tabs happen to sit in must not change the answer.
equal(UntitledDocuments.nextName(takenNames: ["Untitled-3", "Untitled-1"]),
      UntitledDocuments.nextName(takenNames: ["Untitled-1", "Untitled-3"]),
      "the result does not depend on the order of the titles")

// Duplicates (two panes showing the same title) collapse rather than double-count.
equal(UntitledDocuments.nextName(takenNames: ["Untitled-1", "Untitled-1"]), "Untitled-2",
      "a repeated name reserves its index once")

// MARK: - index parsing

equal(UntitledDocuments.index(ofName: "Untitled-1"), 1, "index of Untitled-1")
equal(UntitledDocuments.index(ofName: "Untitled-42"), 42, "index of a multi-digit name")
equal(UntitledDocuments.index(ofName: "Untitled-"), nil, "a bare prefix has no index")
equal(UntitledDocuments.index(ofName: "Untitled-0"), nil, "index 0 is not a scratch name")
equal(UntitledDocuments.index(ofName: "Untitled-01"), nil,
      "a leading zero is rejected, so name to index stays one-to-one")
equal(UntitledDocuments.index(ofName: "Untitled-1x"), nil, "trailing junk disqualifies")
equal(UntitledDocuments.index(ofName: "Untitled-1.txt"), nil, "an extension disqualifies")
equal(UntitledDocuments.index(ofName: "Untitled-١٢"), nil,
      "non-ASCII digits are rejected rather than parsed")
equal(UntitledDocuments.index(ofName: "notes/Untitled-1"), nil, "the prefix must start the name")
equal(UntitledDocuments.index(ofName: ""), nil, "an empty title has no index")

// MARK: - the name it produces is one it can read back

let generated = UntitledDocuments.nextName(takenNames: ["Untitled-1", "Untitled-2"])
equal(UntitledDocuments.index(ofName: generated), 3,
      "a generated name round-trips back through index()")

// A long churn never repeats a live name: take the next name, keep it, repeat.
var live: [String] = []
for step in 1...50 {
    let name = UntitledDocuments.nextName(takenNames: live)
    check(!live.contains(name), "step \(step) handed out a name that was not already open")
    live.append(name)
}
equal(live.count, Set(live).count, "50 consecutive names are all distinct")

print(failures == 0 ? "PASS" : "FAILED (\(failures))")
exit(failures == 0 ? 0 : 1)
