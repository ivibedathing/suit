import Cocoa

// AppKit half of the notification-sound feature (decision logic is the
// Foundation-only NotificationSoundCore). Plays a chosen macOS system sound
// and enumerates the available ones for the Settings pickers.

// Holds a strong reference to the currently-playing NSSound so ARC does not
// deallocate it mid-play. A name that NSSound can't resolve is a silent no-op.
final class NotificationSoundPlayer {
    private var current: NSSound?

    func play(named name: String) {
        guard let sound = NSSound(named: name) else { return }
        current = sound
        sound.play()
    }
}

// Basenames of the built-in macOS system sounds (e.g. "Glass", "Ping"),
// sorted, suitable for NSSound(named:) and the Settings sound pickers.
func availableSystemSounds() -> [String] {
    let dir = "/System/Library/Sounds"
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    return entries
        .filter { $0.hasSuffix(".aiff") }
        .map { ($0 as NSString).deletingPathExtension }
        .sorted()
}
