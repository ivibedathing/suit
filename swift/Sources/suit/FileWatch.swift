import Foundation

// The decisions behind live file watching, factored out of the Cocoa watcher so
// they can be unit-tested standalone (the FileEdit / RoadmapParser pattern —
// Foundation-only, no app or UI dependencies).
//
// A pane that displays a file wants to notice when something else rewrites it:
// Claude editing the open source file, `git checkout` swapping a branch, a
// build regenerating an asset. The kernel tells us *something* happened via a
// DispatchSource; what's genuinely tricky — and worth testing — is the two
// judgements around that raw signal:
//
//  1. **Was the path replaced, or the same file written in place?** Nearly every
//     writer that matters here is atomic: Data.write(.atomic), git, and most
//     editors write a temp file and rename it over the target. The descriptor we
//     hold then points at an unlinked inode that will never fire again, so a
//     delete/rename event isn't "the file went away", it's "re-open the path or
//     go permanently deaf". Treating it as a plain write is the classic bug
//     where a watcher fires exactly once.
//  2. **Did the content actually move?** Events are noisy and arrive in bursts;
//     a stamp comparison keeps a burst of writes from costing a burst of
//     re-reads, and keeps our own save echoing back from looking like an
//     outside change.
//
// The Cocoa half (FileWatcher.swift) owns the descriptor, the DispatchSource and
// the debounce timers; this owns what those mean.

// A filesystem event mask, mirroring the DispatchSource.FileSystemEvent flags we
// subscribe to. Redeclared rather than imported so this file stays testable
// without Dispatch semantics leaking into the decisions.
struct FileWatchEvents: OptionSet, Equatable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    static let write  = FileWatchEvents(rawValue: 1 << 0)  // written in place
    static let extend = FileWatchEvents(rawValue: 1 << 1)  // appended to
    static let delete = FileWatchEvents(rawValue: 1 << 2)  // unlinked out from under us
    static let rename = FileWatchEvents(rawValue: 1 << 3)  // renamed (or replaced by a rename)
    static let revoke = FileWatchEvents(rawValue: 1 << 4)  // revoke(2) / volume unmounted
}

// What the watcher should do about an event burst.
enum FileWatchAction: Equatable {
    // The same inode was written: re-read the path, keep the descriptor.
    case reread
    // The path now points somewhere else (or nowhere): the descriptor is dead,
    // so re-open the path before re-reading. Also implies a re-read, because an
    // atomic replace *is* the content change.
    case rearm
}

enum FileWatchPolicy {
    // How long to wait after an event before re-reading. Long enough that a
    // multi-write burst (a formatter, a generator, a chunked writer) costs one
    // reload rather than one per write; short enough to still read as live.
    static let coalesceInterval: TimeInterval = 0.12

    // Backoff for re-opening a replaced path. During an atomic replace the path
    // is briefly absent, so attempt 0 usually succeeds and the rest only matter
    // for a file that's genuinely gone. The long tail is deliberate: a branch
    // switch, a `git rebase`, or a build that deletes and regenerates the file
    // can leave it missing for tens of seconds, and giving up early means the
    // tab shows stale content until it's reopened. The total (~45 s) is the
    // budget for that; past it the file is gone rather than in flight, and we
    // stop rather than spin a timer forever behind a tab nobody is looking at.
    static let rearmDelays: [TimeInterval] = [0.02, 0.1, 0.3, 1.0, 3.0, 10.0, 30.0]

    static func action(for events: FileWatchEvents) -> FileWatchAction {
        // Replacement wins over a write in a mixed burst: the descriptor is
        // dead either way, and re-arming re-reads too, so nothing is lost.
        if !events.isDisjoint(with: [.delete, .rename, .revoke]) { return .rearm }
        return .reread
    }

    // Delay before re-open attempt `attempt` (0-based); nil once we give up.
    static func rearmDelay(attempt: Int) -> TimeInterval? {
        guard attempt >= 0, attempt < rearmDelays.count else { return nil }
        return rearmDelays[attempt]
    }
}

// A cheap identity for "the file as we last read it". Compared instead of the
// bytes so an event burst that didn't actually change anything — including our
// own atomic save landing back on the path we're watching — costs a stat, not a
// re-read and re-render.
struct FileStamp: Equatable {
    var modificationDate: Date?
    var size: Int
    // The inode: an atomic replace can land inside the same mtime second with
    // the same length, and only the inode gives that away.
    var inode: UInt64

    init(modificationDate: Date?, size: Int, inode: UInt64) {
        self.modificationDate = modificationDate
        self.size = size
        self.inode = inode
    }

    // Nil for a path that doesn't exist or can't be stat'd.
    init?(path: String, fileManager: FileManager = .default) {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path) else { return nil }
        self.modificationDate = attributes[.modificationDate] as? Date
        self.size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        self.inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }

    // Whether the file moved since `previous`. A previously-unknown file (nil)
    // counts as changed so a first read always happens; a file that vanished
    // (`current` nil) does not, because there's nothing to reload *to* — the
    // pane keeps showing the last good content rather than blanking itself.
    static func changed(from previous: FileStamp?, to current: FileStamp?) -> Bool {
        guard let current else { return false }
        guard let previous else { return true }
        return previous != current
    }
}
