import Foundation

// UI-free core for the push-to-talk dictation feature (see Dictation.swift for
// the AVAudioEngine / SFSpeechRecognizer + HUD half). Kept Foundation-only and
// app-independent so it compiles against a standalone assertion driver, the
// RoadmapParser / FeedbackRouting / Recipes pattern (see scripts/dictation-test.sh).
//
// The one piece of dictation logic worth testing without a microphone: turning
// the recognizer's raw transcript into something safe to paste into a terminal
// prompt. Speech recognition can emit leading/trailing whitespace and — mid
// utterance — literal newlines; a stray newline pasted into a Claude prompt (or
// a shell) would submit early, so we flatten everything to single spaces and
// trim the ends before injection.
enum DictationText {
    // Normalize a recognized transcript for injection into a terminal pane:
    // collapse every run of whitespace (spaces, tabs, and newlines alike) to a
    // single space and trim the ends. Returns "" for an all-whitespace or empty
    // transcript, which callers treat as "nothing to send".
    static func normalize(_ raw: String) -> String {
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed
    }

    // Whether a normalized transcript has anything worth injecting. Callers beep
    // / dismiss silently rather than paste an empty string.
    static func isSendable(_ raw: String) -> Bool {
        !normalize(raw).isEmpty
    }
}
