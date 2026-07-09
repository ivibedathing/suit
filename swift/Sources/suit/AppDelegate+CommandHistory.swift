import Cocoa

// The ⌃R command-history overlay (ROADMAP Phase 43): the shell's reverse-i-search
// made native and cross-pane. Reuses the command-palette machinery in explicit-
// items mode (like ⌘P): each remembered command is a row (fuzzy type-to-filter,
// arrows/Enter/Esc), Enter runs it in the focused terminal pane and ⇧Enter types
// it in without submitting (edit-before-run). A destructive-looking command
// trips the same paste-safety confirm a paste would before it submits.
extension AppDelegate {
    @objc func showCommandHistory(_ sender: Any?) {
        let window = activeWindowController()?.window
        // Open immediately with whatever's cached, then freshen the shell-history
        // read (lazy, ≤ once per few seconds) and swap the corpus in place. On a
        // cold first open the cache is empty, so present only once the background
        // read lands — and beep if there's genuinely nothing to search.
        let initial = commandHistoryCommands()
        if !initial.isEmpty { present(initial, over: window) }
        CommandHistoryStore.shared.reloadIfStale { [weak self] in
            guard let self else { return }
            let fresh = self.commandHistoryCommands()
            if self.commandPalette.isVisible {
                self.commandPalette.refreshCommands(fresh)
            } else if !fresh.isEmpty {
                self.present(fresh, over: window)
            } else if initial.isEmpty {
                NSSound.beep()   // no history file and nothing run this session
            }
        }
    }

    private func present(_ commands: [PaletteCommand], over window: NSWindow?) {
        commandPalette.show(
            relativeTo: window,
            commands: commands,
            placeholder: "Search command history — Enter runs · ⇧Enter edits first"
        )
    }

    // The current history corpus projected into palette rows: the command as the
    // title (what the fuzzy filter matches), its source as the right-hand hint.
    private func commandHistoryCommands() -> [PaletteCommand] {
        CommandHistoryStore.shared.commands().map { entry in
            PaletteCommand(
                title: entry.text,
                shortcut: entry.source.hint,
                altAction: { [weak self] in self?.runHistoryCommand(entry.text, submit: false) },
                action: { [weak self] in self?.runHistoryCommand(entry.text, submit: true) }
            )
        }
    }

    // Type a picked command into the focused terminal pane. submit == true runs
    // it (guarded by the paste-safety confirm when it looks destructive);
    // submit == false leaves it in the input box unsubmitted for editing.
    private func runHistoryCommand(_ command: String, submit: Bool) {
        guard let controller = activeWindowController(),
              let terminal = controller.focusedPane()?.content as? TerminalPaneContent else {
            NSSound.beep()
            return
        }
        if submit, let reason = CommandHistory.destructiveWarning(for: command),
           !confirmRunFromHistory(command: command, reason: reason) {
            return
        }
        // Focus the target pane so the user sees the command land / can edit it.
        controller.window.makeKeyAndOrderFront(nil)
        controller.window.makeFirstResponder(terminal.terminalView)
        terminal.terminalView.send(txt: CommandHistory.payload(command: command, submit: submit))
    }

    // The same bar and dialog as the terminal's paste-safety check — running a
    // curl-into-a-shell or rm -rf line out of history is exactly as risky as
    // pasting it.
    private func confirmRunFromHistory(command: String, reason: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Run this command?"
        let preview = command.count > 280 ? String(command.prefix(280)) + "…" : command
        alert.informativeText = "\(reason)\n\n\(preview)"
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
