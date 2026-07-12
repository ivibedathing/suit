import Foundation

// Shared load helper for the ~/.suit JSON stores (Notes, Bookmarks, Favorites,
// SSHHosts, Markers, …). They all followed the same shape — load with `try?`
// and, on *any* failure, start from an empty model — which quietly turned a
// present-but-unreadable file into data loss: because the stores then write the
// empty model back atomically on the next mutation, one malformed file erased
// the user's notes / bookmarks / hosts with no backup.
//
// This distinguishes the two failure modes the old code conflated:
//   • file absent          → return nil; the caller starts empty, and a later
//                            write is safe (there was nothing to lose).
//   • present but unreadable → move it aside to "<name>.corrupt-<epoch>" first,
//                            so the caller's next atomic write can't destroy the
//                            bytes, then return nil. The user (or a future
//                            migration) can still recover the quarantined file.
enum StoreFile {
    static func load<Model: Decodable>(_ type: Model.Type, from path: String) -> Model? {
        let fm = FileManager.default
        // Truly absent (first run / never saved) — start empty; writing is safe.
        guard fm.fileExists(atPath: path) else { return nil }
        let url = URL(fileURLWithPath: path)
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(Model.self, from: data) {
            return decoded
        }
        // Present but unreadable / undecodable: preserve the bytes rather than
        // let the caller's next atomic write clobber them.
        let stamp = Int(Date().timeIntervalSince1970)
        let dest = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".corrupt-\(stamp)")
        try? fm.moveItem(at: url, to: dest)
        NSLog("StoreFile: \(path) was present but unreadable; quarantined to \(dest.lastPathComponent)")
        return nil
    }
}
