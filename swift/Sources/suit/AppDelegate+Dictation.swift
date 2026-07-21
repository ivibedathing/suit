import Cocoa

// Push-to-talk dictation wiring: a pair of local monitors turn holding 🌐+V
// (Globe/Fn plus V) into a speak-while-held gesture that drops recognized text
// into the focused terminal pane. The recognizer + HUD live in Dictation.swift;
// this is just the trigger and the ⌘K entry point.
//
// The chord is 🌐+V rather than 🌐 alone so a bare Globe press keeps whatever
// the system does with it, and so brushing the key while typing can't open a
// microphone. Holding 🌐 arms nothing on its own; V starts the listen, and
// releasing *either* key ends it — hence the second, flags-only monitor.
//
// *Local* monitors (like TabSwitcherPanel's ⌃-release watch) are enough: text
// is injected into the focused pane, so Suit is the active app while dictating
// — no system-global hotkey (and no extra Accessibility grant) required.
extension AppDelegate {
    // kVK_Function — the Fn/Globe key's own keycode, watched so releasing Globe
    // ends the listen even while V is still held.
    private static let fnKeyCode: UInt16 = 63
    // kVK_ANSI_V. Matched by keycode rather than by the event's characters: with
    // Fn held the character payload isn't dependable across layouts.
    private static let vKeyCode: UInt16 = 9

    func installDictationHotkey() {
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard event.keyCode == AppDelegate.vKeyCode else { return event }
            if event.type == .keyDown {
                // isARepeat filters the auto-repeat stream a held V produces —
                // only the first keyDown opens the mic.
                guard event.modifierFlags.contains(.function),
                      !event.isARepeat,
                      !DictationController.shared.isListening else { return event }
                self?.beginDictation()
                return nil  // swallowed, so "v" never lands in the pane
            }
            // Only eat the key-up that closes a listen we started; an ordinary
            // "v" typed into a terminal must pass through untouched.
            guard DictationController.shared.isListening else { return event }
            DictationController.shared.finish()
            return nil
        }

        NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { event in
            guard event.keyCode == AppDelegate.fnKeyCode,
                  !event.modifierFlags.contains(.function),
                  DictationController.shared.isListening else { return event }
            DictationController.shared.finish()
            return event
        }
    }

    private func beginDictation() {
        let terminal = activeWindowController()?.focusedPane()?.terminalContent
        DictationController.shared.begin(into: terminal, over: activeWindowController()?.window)
    }

    // ⌘K "Dictate…": primes microphone/speech permission on first use and
    // reminds you of the 🌐+V hold gesture (a menu action can't hold a key).
    @objc func startDictation(_ sender: Any?) {
        DictationController.shared.primeFromPalette(over: activeWindowController()?.window)
    }
}
