import Foundation

// Notes are plain `.txt` files in ~/.suit/notes/, not records inside a JSON
// blob — and that swap is the whole design. A note opens as an ordinary file
// tab in the pane tree, so it inherits everything the file viewer already does:
// undo, ⌘S and the one-second autosave, ⌘F find/replace, line numbers, the
// dirty chip, splits and tab drag, state restoration across a quit, and the
// watcher that reconciles a rewrite by Claude or $EDITOR. The sidebar used to
// carry its own NSTextView plus its own debounced save against a JSON list —
// a second, weaker editor duplicating all of that. A note that *is* a file
// needs none of it, and gains the rest for free.
//
// The filename is the title, the way it is for every other file in the app:
// no derived-from-first-line title, because renaming a file is how you retitle
// anything else here. The sidebar's Notes tab (NotesView.swift) is now only a
// list that opens them.
//
// This file is Foundation-only — no AppKit — so scripts/notes-test.sh can
// compile it standalone.

// One note on disk. `snippet` is read at scan time (the first 4 KB of the file)
// so a list row can show a preview line without re-reading per draw.
struct NoteFile: Equatable {
    let path: String
    let modifiedAt: Date
    let snippet: String

    var fileName: String { (path as NSString).lastPathComponent }
    var title: String { (fileName as NSString).deletingPathExtension }
}

// Turning what the user typed into a filename, and keeping filenames unique.
// Pure, so the harness can pin the awkward cases (a slash in a title, a title
// that is only punctuation, a collision that has to become "Name 2").
enum NoteNaming {
    static let fileExtension = "txt"
    // Long enough for a real sentence-as-title, short enough that the sidebar
    // row and every path length limit stay comfortable.
    static let maxTitleLength = 60

    // A note's filename for the title the user typed. `/` and `:` are the two
    // characters the filesystem and Finder disagree about, so both become a
    // dash rather than silently splitting the name into directories; newlines
    // and other control characters collapse into the surrounding spaces. A
    // leading dot is dropped — a hidden note is a note the list can't show.
    static func fileName(forTitle raw: String) -> String {
        var cleaned = ""
        for scalar in raw.unicodeScalars {
            if scalar == "/" || scalar == ":" {
                cleaned.append("-")
            } else if CharacterSet.controlCharacters.contains(scalar) {
                cleaned.append(" ")
            } else {
                cleaned.unicodeScalars.append(scalar)
            }
        }
        // Collapse whitespace runs (including the ones the substitutions above
        // just made) so "a    b" and "a\n\nb" both title as "a b".
        let collapsed = cleaned.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        var title = String(collapsed.prefix(maxTitleLength)).trimmingCharacters(in: .whitespaces)
        while title.hasPrefix(".") { title.removeFirst() }
        title = title.trimmingCharacters(in: .whitespaces)
        if title.isEmpty { title = "Untitled" }
        return title + "." + fileExtension
    }

    // The title a note's text suggests: its first non-empty line. Used when a
    // note is created from content rather than from a name the user typed
    // (the terminal's selection capture).
    static func title(fromText text: String) -> String {
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { return line }
        }
        return ""
    }

    // "Note.txt" → "Note 2.txt" → "Note 3.txt" until free. Compared
    // case-insensitively because the volume this lands on almost certainly is:
    // "note.txt" and "Note.txt" are one file, and moveItem onto it would fail.
    static func uniqueFileName(_ desired: String, existing: Set<String>) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        guard taken.contains(desired.lowercased()) else { return desired }
        let base = (desired as NSString).deletingPathExtension
        let ext = (desired as NSString).pathExtension
        var attempt = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(attempt)" : "\(base) \(attempt).\(ext)"
            if !taken.contains(candidate.lowercased()) { return candidate }
            attempt += 1
        }
    }
}

// The notes directory, listed and mutated. Deliberately thin: it creates,
// renames, trashes and lists files — the *contents* are the file viewer's
// business, and nothing here caches or writes note text after creation.
// A watcher on the directory means a note created, renamed or deleted by any
// other window (or by hand in Finder, or by Claude) refreshes every list.
final class NotesStore {
    static let shared = NotesStore()
    static let didUpdate = Notification.Name("dev.kosych.suit.NotesStore.didUpdate")

    private(set) var notes: [NoteFile] = []

    private var watcher: FileWatcher?

    // $HOME rather than NSHomeDirectory(), same as ClaudeIntegration: an
    // overridden $HOME sandboxes the directory for harness runs. Computed, not
    // stored, so a harness that re-points $HOME between cases is honored.
    private static var suitDirectory: String {
        (ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()) + "/.suit"
    }
    static var directory: String { suitDirectory + "/notes" }
    // The two shapes notes were kept in before they were files: the list in
    // notes.json, and before that a single free-text notes.txt. Both are read
    // once and then left alone on disk — never rewritten, never deleted, so a
    // botched import is always recoverable by hand.
    static var legacyJSONPath: String { suitDirectory + "/notes.json" }
    static var legacyTextPath: String { suitDirectory + "/notes.txt" }

    // `watching: false` is for harnesses: a DispatchSource on a directory the
    // test is about to delete is noise, and there's no run loop to fire it.
    init(watching: Bool = true) {
        migrateIfNeeded()
        reload()
        guard watching else { return }
        watcher = FileWatcher(path: Self.directory) { [weak self] in
            self?.reload()
            self?.post()
        }
    }

    // MARK: - Reading

    // Rescans the directory: a flat listing plus a 4 KB head read per note —
    // cheap at any plausible note count, and the only thing that has to be
    // right after an outside change.
    func reload() {
        let fm = FileManager.default
        var found: [NoteFile] = []
        for name in (try? fm.contentsOfDirectory(atPath: Self.directory)) ?? [] {
            guard !name.hasPrefix("."),
                  (name as NSString).pathExtension.lowercased() == NoteNaming.fileExtension else { continue }
            let path = Self.directory + "/" + name
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            found.append(NoteFile(
                path: path,
                modifiedAt: modified ?? Date(timeIntervalSince1970: 0),
                snippet: Self.snippet(ofFileAt: path, title: (name as NSString).deletingPathExtension)
            ))
        }
        // Most-recently-edited first, the order the JSON list had. Ties (a bulk
        // import stamps several files in the same second) fall back to the name
        // so the list can't reshuffle between two equal scans.
        notes = found.sorted {
            $0.modifiedAt == $1.modifiedAt
                ? $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
                : $0.modifiedAt > $1.modifiedAt
        }
    }

    func note(atPath path: String) -> NoteFile? {
        notes.first { $0.path == path }
    }

    // The row's detail text: the first line of the file's head worth showing.
    // A line identical to the title is skipped — a note captured from a
    // selection, or imported from the old list, leads with the very line its
    // title came from, and a row reading "Roadmap ideas · Roadmap ideas" spends
    // its second line saying nothing. Only the head is read: a note is a text
    // file and may be arbitrarily long.
    private static func snippet(ofFileAt path: String, title: String) -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 4096)) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line == title { continue }
            return String(line.prefix(200))
        }
        return ""
    }

    private func existingFileNames() -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: Self.directory)) ?? [])
    }

    // MARK: - Mutating

    // Creates a note file and returns its path (nil if the write failed). The
    // caller opens it — creating a note and not showing it would be pointless,
    // but this store knows nothing about panes.
    @discardableResult
    func createNote(title: String = "", text: String = "") -> String? {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: Self.directory, withIntermediateDirectories: true)
        let wanted = title.isEmpty ? NoteNaming.title(fromText: text) : title
        let name = NoteNaming.uniqueFileName(
            NoteNaming.fileName(forTitle: wanted),
            existing: existingFileNames()
        )
        let path = Self.directory + "/" + name
        do {
            try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            return nil
        }
        reload()
        post()
        return path
    }

    // Renames a note to `raw` as a title, returning the new path. A rename onto
    // a name already taken lands as "Name 2" rather than failing or clobbering.
    @discardableResult
    func renameNote(atPath path: String, toTitle raw: String) -> String? {
        let desired = NoteNaming.fileName(forTitle: raw)
        let current = (path as NSString).lastPathComponent
        guard desired != current else { return path }
        // Exclude the note's own name so re-casing it ("notes" → "Notes")
        // doesn't collide with itself and land as "Notes 2".
        var existing = existingFileNames()
        existing.remove(current)
        let name = NoteNaming.uniqueFileName(desired, existing: existing)
        let destination = Self.directory + "/" + name
        do {
            try FileManager.default.moveItem(atPath: path, toPath: destination)
        } catch {
            return nil
        }
        reload()
        post()
        return destination
    }

    // Trashed, not unlinked: a note is the user's writing, and the Files tab's
    // "Move to Trash" sets the expectation that deletion here is recoverable.
    @discardableResult
    func deleteNote(atPath path: String) -> Bool {
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        } catch {
            return false
        }
        reload()
        post()
        return true
    }

    // Right-click "Create Note from Selection" in a terminal: the capture
    // becomes a note file titled after its first line.
    @discardableResult
    func addNoteFromSelection(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return createNote(text: trimmed + "\n")
    }

    private func post() {
        NotificationCenter.default.post(name: Self.didUpdate, object: nil)
    }

    // MARK: - Migration

    // Only the shape the importer needs, and every field optional: a state file
    // written by an older or newer Suit must still load.
    private struct LegacyNote: Decodable {
        let text: String?
        let updatedAt: TimeInterval?
    }

    // The notes directory not existing *is* the "not yet migrated" marker — no
    // flag file, and nothing to keep in sync. Once it exists (even empty, e.g.
    // the user trashed every imported note) the legacy files are never read
    // again, so a deleted note can't resurrect itself at the next launch.
    private func migrateIfNeeded() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: Self.directory) else { return }
        guard (try? fm.createDirectory(atPath: Self.directory, withIntermediateDirectories: true)) != nil else { return }

        var used: Set<String> = []
        if let data = fm.contents(atPath: Self.legacyJSONPath),
           let legacy = try? JSONDecoder().decode([LegacyNote].self, from: data),
           !legacy.isEmpty {
            for note in legacy {
                guard let text = note.text,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                // Each note keeps its own updatedAt as the file's mtime, so the
                // imported list comes back in the order it was left in.
                importNote(
                    text: text,
                    modified: note.updatedAt.map(Date.init(timeIntervalSince1970:)),
                    used: &used
                )
            }
            return
        }
        // Pre-list format: one free-text file, imported as a single note.
        if let text = try? String(contentsOfFile: Self.legacyTextPath, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let modified = (try? fm.attributesOfItem(atPath: Self.legacyTextPath))?[.modificationDate] as? Date
            importNote(text: text, modified: modified, used: &used)
        }
    }

    private func importNote(text: String, modified: Date?, used: inout Set<String>) {
        let name = NoteNaming.uniqueFileName(
            NoteNaming.fileName(forTitle: NoteNaming.title(fromText: text)),
            existing: used
        )
        used.insert(name)
        let path = Self.directory + "/" + name
        guard (try? Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)) != nil else { return }
        if let modified {
            try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path)
        }
    }
}
