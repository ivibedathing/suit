import Cocoa

// Saved layouts / named workspaces (ROADMAP Phase 41): the UI verbs on top of
// the `LayoutStore` core. Save snapshots the active window with
// `captureState()` (the same `SavedWindow` quit-time restoration uses); open
// rebuilds a saved layout in a *new* window through the exact replay path
// (`init(restoring:)`), so a tab whose file/root is gone collapses its pane out
// for free. Rename/delete/overwrite round out the management surface. Surfaced
// from the palette and the Screen menu.
extension AppDelegate {

    // MARK: - Save

    // "Save Layout As…": prompt for a name, confirm before overwriting an
    // existing one. The snapshot is taken now (before the async prompt), so it
    // captures the layout the user is looking at.
    @objc func saveLayoutAs(_ sender: Any?) {
        guard let controller = activeWindowController() else { NSSound.beep(); return }
        let snapshot = controller.captureState()
        OverlayPromptController.shared.ask(
            caption: "Save Layout As",
            placeholder: "Layout name…",
            over: controller.window
        ) { [weak controller] name in
            let clean = LayoutCatalog.normalized(name)
            guard !clean.isEmpty else { return }
            if LayoutStore.shared.exists(name: clean) {
                let alert = NSAlert()
                alert.messageText = "Replace layout “\(clean)”?"
                alert.informativeText = "A saved layout with that name already exists."
                alert.addButton(withTitle: "Replace")
                alert.addButton(withTitle: "Cancel")
                _ = controller  // keep the window alive for the modal's lifetime
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            LayoutStore.shared.save(name: clean, window: snapshot)
        }
    }

    // MARK: - Open

    // "Open Layout…": pick a saved layout (palette in explicit-items mode) and
    // rebuild it in a new window.
    @objc func openLayout(_ sender: Any?) {
        guard let controller = activeWindowController() else { NSSound.beep(); return }
        let layouts = LayoutStore.shared.layouts
        guard !layouts.isEmpty else { presentNoLayouts(over: controller.window); return }
        paletteFileIndex = nil
        commandPalette.show(
            relativeTo: controller.window,
            commands: layouts.map { layout in
                PaletteCommand(title: Self.layoutRowTitle(layout), shortcut: nil) { [weak self] in
                    self?.restoreLayout(layout)
                }
            },
            placeholder: "Open layout…"
        )
    }

    // Rebuild a saved layout in a fresh window via the state-restoration replay
    // path — terminals restart as fresh shells in their old cwd, and tabs whose
    // file/root is gone drop out (their pane collapses), exactly like quit-time
    // restoration.
    func restoreLayout(_ layout: SavedLayout) {
        let controller = TerminalWindowController(
            appDelegate: self,
            startDirectory: savedWorkingDirectory(),
            restoring: layout.window
        )
        windowControllers.append(controller)
        controller.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Manage (rename / delete)

    @objc func renameLayout(_ sender: Any?) {
        guard let controller = activeWindowController() else { NSSound.beep(); return }
        let layouts = LayoutStore.shared.layouts
        guard !layouts.isEmpty else { presentNoLayouts(over: controller.window); return }
        paletteFileIndex = nil
        commandPalette.show(
            relativeTo: controller.window,
            commands: layouts.map { layout in
                PaletteCommand(title: layout.name, shortcut: nil) { [weak controller] in
                    OverlayPromptController.shared.ask(
                        caption: "Rename Layout",
                        text: layout.name,
                        placeholder: "New name…",
                        over: controller?.window
                    ) { newName in
                        LayoutStore.shared.rename(from: layout.name, to: newName)
                    }
                }
            },
            placeholder: "Rename layout…"
        )
    }

    @objc func deleteLayout(_ sender: Any?) {
        guard let controller = activeWindowController() else { NSSound.beep(); return }
        let layouts = LayoutStore.shared.layouts
        guard !layouts.isEmpty else { presentNoLayouts(over: controller.window); return }
        paletteFileIndex = nil
        commandPalette.show(
            relativeTo: controller.window,
            commands: layouts.map { layout in
                PaletteCommand(title: layout.name, shortcut: nil) {
                    let alert = NSAlert()
                    alert.messageText = "Delete layout “\(layout.name)”?"
                    alert.informativeText = "This can’t be undone."
                    alert.addButton(withTitle: "Delete")
                    alert.addButton(withTitle: "Cancel")
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                    LayoutStore.shared.remove(name: layout.name)
                }
            },
            placeholder: "Delete layout…"
        )
    }

    // MARK: - Helpers

    private static func layoutRowTitle(_ layout: SavedLayout) -> String {
        let count = layout.window.tabs.count
        return "\(layout.name) · \(count) tab\(count == 1 ? "" : "s")"
    }

    private func presentNoLayouts(over window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "No saved layouts"
        alert.informativeText = "Use “Save Layout As…” to snapshot the current window first."
        alert.addButton(withTitle: "OK")
        if let window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}
