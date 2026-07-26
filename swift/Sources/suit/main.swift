import Cocoa

// The app entry point: constructs the AppDelegate, wires it to the shared
// NSApplication as a regular (Dock-visible) app, and starts the run loop.
let app = NSApplication.shared
// Before the delegate exists, because AppDelegate.currentFont asks for Hack by
// name the instant the delegate is built. Idempotent, so the identical call in
// that initializer (which is what non-main.swift entry points rely on) is free.
BundledFonts.ensureRegistered()
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
