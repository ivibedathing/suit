import Cocoa

// The app entry point: constructs the AppDelegate, wires it to the shared
// NSApplication as a regular (Dock-visible) app, and starts the run loop.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
