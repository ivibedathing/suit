import Foundation

// The editable file viewer's save/dirty logic, factored out of the Cocoa pane
// so it can be unit-tested standalone (the RoadmapParser / Recipes / TaskLaunch
// pattern — Foundation-only, no app or UI dependencies). ROADMAP Phase 37.
//
// FileEditState tracks whether the live buffer has diverged from what's on disk
// and, when the file changes underneath the buffer, decides how to reconcile.
// The Cocoa layer (FileViewerPane) owns the NSTextView, the debounce Timer and
// the dirty indicators; this owns the decisions those surfaces render.

// What to do when the file on disk changed underneath an open buffer.
enum ExternalChangeResolution: Equatable {
    case ignore   // disk already matches the buffer (e.g. our own save) — nothing to do
    case reload   // buffer is clean — silently adopt the disk version
    case warn     // buffer has unsaved edits — ask before clobbering them
}

// Saved-vs-current state for one open file. `savedText` is the last content
// known to be on disk (set on load and after a successful save); `isDirty` is
// whether the live buffer has diverged from it.
struct FileEditState: Equatable {
    private(set) var savedText: String
    private(set) var isDirty: Bool = false

    init(savedText: String = "") { self.savedText = savedText }

    // The buffer changed to `current`. Returns true only when the dirty flag
    // *flips* (off→on or on→off), so the caller repaints the dirty indicator on
    // a transition rather than on every keystroke. Editing back to exactly the
    // saved content clears dirty (no phantom "unsaved" star after an undo).
    @discardableResult
    mutating func edited(to current: String) -> Bool {
        let nowDirty = current != savedText
        let flipped = nowDirty != isDirty
        isDirty = nowDirty
        return flipped
    }

    // A successful write of `text`: it becomes the saved baseline, buffer clean.
    mutating func markSaved(_ text: String) {
        savedText = text
        isDirty = false
    }

    // Loading a fresh file, or adopting a reload, resets the baseline clean.
    mutating func markLoaded(_ text: String) {
        savedText = text
        isDirty = false
    }

    // The file on disk now reads `diskText` while the live buffer holds
    // `bufferText`. Decide how to reconcile: a disk that already matches the
    // buffer is our own write echoing back (ignore); with no local edits the
    // newer disk version simply wins (reload); with unsaved edits the two have
    // diverged and only the user can choose (warn).
    func resolveExternalChange(diskText: String, bufferText: String) -> ExternalChangeResolution {
        if diskText == bufferText { return .ignore }
        return isDirty ? .warn : .reload
    }
}

// The atomic write behind ⌘S and autosave, split out so the harness can assert
// bytes land exactly and atomically. UTF-8, `.atomic` (write-to-temp-then-
// rename) so a crash mid-write never leaves a truncated source file.
enum FileEditWriter {
    static func write(_ text: String, toPath path: String) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
