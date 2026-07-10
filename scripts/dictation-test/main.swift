import Foundation

// Standalone assertion driver for the dictation text core, compiled against
// swift/Sources/suit/DictationText.swift (Foundation-only) by
// scripts/dictation-test.sh. Mirrors the RoadmapParser / FeedbackRouting /
// Recipes standalone-test pattern: no app, no UI, no microphone — just the
// transcript normalization that feeds SessionControl.send.

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok: \(message)")
    } else {
        print("  FAIL: \(message)")
        failures += 1
    }
}

print("== DictationText.normalize ==")
check(DictationText.normalize("hello world") == "hello world", "plain text is left intact")
check(DictationText.normalize("  hello world  ") == "hello world", "leading/trailing whitespace trimmed")
check(DictationText.normalize("hello   world") == "hello world", "internal whitespace runs collapse to one space")
check(DictationText.normalize("line one\nline two") == "line one line two", "embedded newlines flatten to spaces")
check(DictationText.normalize("a\n\n\tb  c") == "a b c", "mixed newlines/tabs/spaces all collapse")
check(DictationText.normalize("") == "", "empty in → empty out")
check(DictationText.normalize("   \n\t  ") == "", "all-whitespace → empty")

print("== DictationText.isSendable ==")
check(DictationText.isSendable("hi") == true, "non-empty transcript is sendable")
check(DictationText.isSendable("   ") == false, "whitespace-only transcript is not sendable")
check(DictationText.isSendable("") == false, "empty transcript is not sendable")
check(DictationText.isSendable("\n\n") == false, "newline-only transcript is not sendable")

print("")
if failures == 0 {
    print("ALL PASSED")
    exit(0)
} else {
    print("\(failures) FAILED")
    exit(1)
}
