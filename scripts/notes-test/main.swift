import Foundation

// Standalone assertion driver for the notes core, compiled against
// swift/Sources/suit/Notes.swift (Foundation-only) by scripts/notes-test.sh.
// Mirrors the Recipes / Layouts standalone-test pattern: no app, no UI.
//
// Two halves. The pure half pins NoteNaming — turning a typed title into a
// filename (the characters that must not reach the filesystem, the truncation,
// the "Untitled" fallback) and the collision suffix. The IO half drives a real
// NotesStore against scratch $HOMEs: create/list/rename, the scan's filtering
// and ordering, and — the part with real user data at stake — the one-way
// import of the two formats notes used to live in (notes.json, and the older
// free-text notes.txt), including that it happens exactly once.
//
// Deletion is deliberately not covered: NotesStore.deleteNote trashes the file,
// and FileManager's trash is the real user's ~/.Trash regardless of $HOME — a
// test for it would litter the machine running it.

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
// The wrapper hands us a scratch $HOME; each scenario gets its own subdirectory
// under it so a migration test always starts from a home with no notes/.
let scratchRoot = ProcessInfo.processInfo.environment["HOME"] ?? NSTemporaryDirectory()
var homeCount = 0
@discardableResult
func freshHome(_ label: String) -> String {
    homeCount += 1
    let home = scratchRoot + "/\(homeCount)-\(label)"
    try? fm.createDirectory(atPath: home + "/.suit", withIntermediateDirectories: true)
    setenv("HOME", home, 1)
    return home
}

func write(_ text: String, to path: String, modified: Date? = nil) {
    try? Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    if let modified {
        try? fm.setAttributes([.modificationDate: modified], ofItemAtPath: path)
    }
}

func read(_ path: String) -> String? {
    try? String(contentsOfFile: path, encoding: .utf8)
}

func names(_ store: NotesStore) -> [String] {
    store.notes.map { $0.fileName }
}

// MARK: - NoteNaming.fileName

print("== NoteNaming.fileName(forTitle:) ==")
check(NoteNaming.fileName(forTitle: "Roadmap ideas") == "Roadmap ideas.txt", "plain title keeps its spaces and gains .txt")
check(NoteNaming.fileName(forTitle: "a/b:c") == "a-b-c.txt", "slash and colon become dashes, never path separators")
check(NoteNaming.fileName(forTitle: "line one\nline two") == "line one line two.txt", "newlines collapse into a single space")
check(NoteNaming.fileName(forTitle: "a    b") == "a b.txt", "whitespace runs collapse")
check(NoteNaming.fileName(forTitle: "   ") == "Untitled.txt", "blank title falls back to Untitled")
check(NoteNaming.fileName(forTitle: "") == "Untitled.txt", "empty title falls back to Untitled")
check(NoteNaming.fileName(forTitle: "...hidden") == "hidden.txt", "leading dots dropped — a hidden note is invisible to the list")
check(NoteNaming.fileName(forTitle: ".") == "Untitled.txt", "a title of only dots still yields a name")
let long = NoteNaming.fileName(forTitle: String(repeating: "x", count: 200))
check(long == String(repeating: "x", count: NoteNaming.maxTitleLength) + ".txt", "long title truncated to maxTitleLength")

print("== NoteNaming.title(fromText:) ==")
check(NoteNaming.title(fromText: "\n\n  hello \nworld") == "hello", "first non-empty line, trimmed")
check(NoteNaming.title(fromText: "\n \n") == "", "no content → no suggested title")

print("== NoteNaming.uniqueFileName ==")
check(NoteNaming.uniqueFileName("A.txt", existing: []) == "A.txt", "free name is used as-is")
check(NoteNaming.uniqueFileName("A.txt", existing: ["A.txt"]) == "A 2.txt", "taken name gains a 2")
check(NoteNaming.uniqueFileName("A.txt", existing: ["A.txt", "A 2.txt"]) == "A 3.txt", "suffix walks past every taken name")
check(NoteNaming.uniqueFileName("A.txt", existing: ["a.TXT"]) == "A 2.txt", "collision is case-insensitive, like the volume")

// MARK: - Create, list, snippet

print("== create / list ==")
freshHome("create")
var store = NotesStore(watching: false)
check(store.notes.isEmpty, "a home with no notes lists nothing")
check(fm.fileExists(atPath: NotesStore.directory), "the notes directory is created on first use")

let first = store.createNote(title: "First note", text: "hello\nworld")
check(first.map { ($0 as NSString).lastPathComponent } == "First note.txt", "the title is the filename")
check(read(first ?? "") == "hello\nworld", "the note's text is on disk verbatim")
check(names(store) == ["First note.txt"], "the new note is listed")
check(store.notes.first?.title == "First note", "title is the filename without .txt")
check(store.notes.first?.snippet == "hello", "snippet is the first non-empty line")

let duplicate = store.createNote(title: "First note", text: "second")
check(duplicate.map { ($0 as NSString).lastPathComponent } == "First note 2.txt", "a second note with the same title doesn't clobber the first")
check(read(first ?? "") == "hello\nworld", "the original file is untouched by the collision")
check(store.notes.count == 2, "both notes are listed")

let untitled = store.createNote()
check(untitled.map { ($0 as NSString).lastPathComponent } == "Untitled.txt", "a note created with no title lands as Untitled")
check(read(untitled ?? "") == "", "an untitled note starts empty")

let echoed = store.createNote(title: "Echoed", text: "Echoed\n\nthe real second line")
check(store.note(atPath: echoed ?? "")?.snippet == "the real second line", "a first line that just repeats the title is skipped")
let titleOnly = store.createNote(title: "Bare", text: "Bare\n")
check(store.note(atPath: titleOnly ?? "")?.snippet == "", "a note that is only its title has no snippet, not a repeat of itself")

// MARK: - Scan filtering and ordering

print("== scan ==")
freshHome("scan")
store = NotesStore(watching: false)
let dir = NotesStore.directory
write("older", to: dir + "/Old.txt", modified: Date(timeIntervalSince1970: 1000))
write("newer", to: dir + "/New.txt", modified: Date(timeIntervalSince1970: 2000))
write("# not a note", to: dir + "/readme.md")
write("hidden", to: dir + "/.secret.txt")
try? fm.createDirectory(atPath: dir + "/folder.txt", withIntermediateDirectories: true)
store.reload()
check(names(store) == ["New.txt", "Old.txt"], "most-recently-modified first; non-.txt, dotfiles and directories are skipped")

write("touched", to: dir + "/Old.txt", modified: Date(timeIntervalSince1970: 3000))
store.reload()
check(names(store) == ["Old.txt", "New.txt"], "an outside edit re-sorts the list on the next scan")

// Equal mtimes (what a bulk import produces) must not reshuffle between scans.
write("a", to: dir + "/New.txt", modified: Date(timeIntervalSince1970: 5000))
write("b", to: dir + "/Old.txt", modified: Date(timeIntervalSince1970: 5000))
store.reload()
let firstOrder = names(store)
store.reload()
check(firstOrder == names(store) && firstOrder == ["New.txt", "Old.txt"], "equal timestamps fall back to a stable name order")

// MARK: - Rename

print("== rename ==")
freshHome("rename")
store = NotesStore(watching: false)
let source = store.createNote(title: "Draft", text: "body")!
let renamed = store.renameNote(atPath: source, toTitle: "Final")
check(renamed.map { ($0 as NSString).lastPathComponent } == "Final.txt", "rename moves the file to the new title")
check(!fm.fileExists(atPath: source), "the old filename is gone")
check(read(renamed ?? "") == "body", "the text survives the rename")
check(names(store) == ["Final.txt"], "the list follows the rename")

store.createNote(title: "Taken", text: "")
let collided = store.renameNote(atPath: renamed!, toTitle: "Taken")
check(collided.map { ($0 as NSString).lastPathComponent } == "Taken 2.txt", "renaming onto a taken title suffixes rather than clobbering")
check(read(NotesStore.directory + "/Taken.txt") == "", "the note that owned the name is untouched")

let recased = store.renameNote(atPath: collided!, toTitle: "TAKEN 2")
check(recased.map { ($0 as NSString).lastPathComponent } == "TAKEN 2.txt", "a case-only rename doesn't collide with itself")

check(store.renameNote(atPath: NotesStore.directory + "/gone.txt", toTitle: "x") == nil, "renaming a missing note reports failure")

// MARK: - Selection capture

print("== addNoteFromSelection ==")
freshHome("selection")
store = NotesStore(watching: false)
let captured = store.addNoteFromSelection("  git status\n  git log  ")
check(captured.map { ($0 as NSString).lastPathComponent } == "git status.txt", "a captured selection is titled after its first line")
check(read(captured ?? "") == "git status\n  git log\n", "the capture is trimmed at the ends and newline-terminated")
check(store.addNoteFromSelection("   ") == nil, "a blank capture creates nothing")
check(store.notes.count == 1, "…and doesn't reach the list")

// MARK: - Migration from notes.json

print("== migration: notes.json ==")
freshHome("migrate-json")
write("""
[{"id":"DD19F05C-EF67-40D3-A08E-A7FECF4F195B","text":"Alpha note\\nbody line","createdAt":1,"updatedAt":2000},
 {"text":"Beta","updatedAt":1000,"unknownFutureKey":true},
 {"text":"   ","updatedAt":3000}]
""", to: NotesStore.legacyJSONPath)
store = NotesStore(watching: false)
check(names(store) == ["Alpha note.txt", "Beta.txt"], "each JSON note becomes a file, newest first, blank ones skipped")
check(read(NotesStore.directory + "/Alpha note.txt") == "Alpha note\nbody line", "the note's full text is imported, not just its title")
check(store.notes.first?.modifiedAt == Date(timeIntervalSince1970: 2000), "updatedAt is preserved as the file's mtime")
check(fm.fileExists(atPath: NotesStore.legacyJSONPath), "notes.json is left on disk — the import is never destructive")

// Once-only: the directory's existence is the marker, so a note deleted after
// the import must not come back at the next launch.
try? fm.removeItem(atPath: NotesStore.directory + "/Beta.txt")
store = NotesStore(watching: false)
check(names(store) == ["Alpha note.txt"], "a second launch doesn't re-import — a deleted note stays deleted")

print("== migration: notes.txt ==")
freshHome("migrate-txt")
write("Features\n1. Save layout of terminals.", to: NotesStore.legacyTextPath, modified: Date(timeIntervalSince1970: 4000))
store = NotesStore(watching: false)
check(names(store) == ["Features.txt"], "the pre-list free-text file imports as a single note")
check(read(NotesStore.directory + "/Features.txt") == "Features\n1. Save layout of terminals.", "its whole text is kept")
check(store.notes.first?.modifiedAt == Date(timeIntervalSince1970: 4000), "notes.txt's mtime carries over")

print("== migration: notes.json wins over notes.txt ==")
freshHome("migrate-both")
write("[{\"text\":\"From JSON\",\"updatedAt\":10}]", to: NotesStore.legacyJSONPath)
write("From TXT", to: NotesStore.legacyTextPath)
store = NotesStore(watching: false)
check(names(store) == ["From JSON.txt"], "the newer format is imported and the older one ignored")

print("== migration: junk legacy file ==")
freshHome("migrate-junk")
write("this is not json at all", to: NotesStore.legacyJSONPath)
store = NotesStore(watching: false)
check(store.notes.isEmpty, "an unreadable notes.json imports nothing")
check(fm.fileExists(atPath: NotesStore.directory), "…but the directory is still created, so it isn't retried forever")

print("== migration: duplicate titles ==")
freshHome("migrate-dupes")
write("[{\"text\":\"Same\",\"updatedAt\":20},{\"text\":\"Same\",\"updatedAt\":10}]", to: NotesStore.legacyJSONPath)
store = NotesStore(watching: false)
check(Set(names(store)) == ["Same.txt", "Same 2.txt"], "two legacy notes with the same first line both survive the import")

print(failures == 0 ? "\nAll notes assertions passed." : "\n\(failures) assertion(s) FAILED.")
exit(failures == 0 ? 0 : 1)
