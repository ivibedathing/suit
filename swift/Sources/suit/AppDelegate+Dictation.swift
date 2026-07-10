import Cocoa

// Push-to-talk dictation wiring: a local flagsChanged monitor turns holding the
// 🌐 (Fn/Globe) key into a speak-while-held gesture that drops recognized text
// into the focused terminal pane. The recognizer + HUD live in Dictation.swift;
// this is just the trigger and the ⌘K entry point.
//
// A *local* monitor (like TabSwitcherPanel's ⌃-release watch) is enough: text
// is injected into the focused pane, so Suit is the active app while dictating
// — no system-global hotkey (and no extra Accessibility grant) required.
extension AppDelegate {
    // kVK_Function — the Fn/Globe key's own keycode. We key off it specifically
    // so arrow keys and F-keys (which also set the .function flag while held)
    // don't start dictation.
    private static let fnKeyCode: UInt16 = 63

    func installDictationHotkey() {
        NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            guard event.keyCode == AppDelegate.fnKeyCode else { return event }
            if event.modifierFlags.contains(.function) {
                self?.beginDictation()
            } else {
                DictationController.shared.finish()
            }
            return event
        }
    }

    private func beginDictation() {
        let terminal = activeWindowController()?.focusedPane()?.terminalContent
        DictationController.shared.begin(into: terminal, over: activeWindowController()?.window)
    }

    // ⌘K "Dictate…": primes microphone/speech permission on first use and
    // reminds you of the 🌐 hold gesture (a menu action can't hold a key).
    @objc func startDictation(_ sender: Any?) {
        DictationController.shared.primeFromPalette(over: activeWindowController()?.window)
    }
}
