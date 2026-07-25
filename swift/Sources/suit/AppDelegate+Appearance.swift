import Cocoa

// The visual settings verbs: word wrap and the font/color/cursor `…Changed`
// handlers that apply a new value live across every window. Behavior toggles
// live in AppDelegate+Settings; persistence for both is
// AppDelegate+SettingsPersistence.
extension AppDelegate {
    // MARK: - Word wrap (file viewers)

    @objc func toggleWordWrap(_ sender: Any?) {
        wordWrapChanged(!wordWrapEnabled)
    }

    func wordWrapChanged(_ wrap: Bool) {
        wordWrapEnabled = wrap
        for controller in windowControllers {
            controller.applyWordWrap(wordWrapEnabled)
        }
        saveSettings()
    }

    // MARK: - Settings

    @objc func showSettings(_ sender: Any?) {
        settingsWindowController.show()
    }

    func beginChoosingFont() {
        NSFontManager.shared.target = self
        NSFontManager.shared.setSelectedFont(currentFont, isMultiple: false)
        NSFontManager.shared.orderFrontFontPanel(self)
    }

    // The exact selector NSFontManager sends up the responder chain when the user
    // picks a font in the font panel.
    @objc func changeFont(_ sender: NSFontManager?) {
        guard let sender else { return }
        currentFont = sender.convert(currentFont)
        for controller in windowControllers {
            controller.applyFont(currentFont)
        }
        settingsWindowController.updateFontLabel(currentFont)
        saveSettings()
    }

    // Cmd-=/Cmd--: size just the focused pane. Cmd-Shift-=/Cmd-Shift--: every
    // pane steps relative to its own size (so per-pane overrides keep their
    // offset) and the global default moves with them for future panes.
    @objc func increaseFontSize(_ sender: Any?) {
        adjustFocusedPaneFontSize(by: 1)
    }

    @objc func decreaseFontSize(_ sender: Any?) {
        adjustFocusedPaneFontSize(by: -1)
    }

    @objc func increaseAllFontSizes(_ sender: Any?) {
        adjustAllPaneFontSizes(by: 1)
    }

    @objc func decreaseAllFontSizes(_ sender: Any?) {
        adjustAllPaneFontSizes(by: -1)
    }

    private func adjustFocusedPaneFontSize(by delta: CGFloat) {
        guard let pane = activeWindowController()?.focusedPane() else {
            NSSound.beep()
            return
        }
        adjustPaneFontSize(pane, by: delta)
    }

    private func adjustAllPaneFontSizes(by delta: CGFloat) {
        currentFont = NSFontManager.shared.convert(currentFont, toSize: clampedFontSize(currentFont.pointSize + delta))
        for controller in windowControllers {
            for pane in controller.panes {
                adjustPaneFontSize(pane, by: delta)
            }
        }
        settingsWindowController.updateFontLabel(currentFont)
        saveSettings()
    }

    private func adjustPaneFontSize(_ pane: Pane, by delta: CGFloat) {
        let font = pane.appliedFont ?? currentFont
        pane.setFont(NSFontManager.shared.convert(font, toSize: clampedFontSize(font.pointSize + delta)))
    }

    private func clampedFontSize(_ size: CGFloat) -> CGFloat {
        min(maxFontSize, max(minFontSize, size))
    }

    func fontSizeChanged(_ size: CGFloat) {
        currentFont = NSFontManager.shared.convert(currentFont, toSize: size)
        for controller in windowControllers {
            controller.applyFont(currentFont)
        }
        settingsWindowController.updateFontLabel(currentFont)
        saveSettings()
    }

    func textColorChanged(_ color: NSColor) {
        currentTextColor = color
        for controller in windowControllers {
            controller.applyTextColor(color)
        }
        saveSettings()
    }

    // MARK: - Theme switches that move a default

    // The app-level terminal ground is a persisted user setting, but its shipped
    // value is a theme token ("Midnight" — Theme.terminalBg). So on a theme
    // switch we retarget it when, and only when, it still holds the outgoing
    // theme's ground: that's the signal the user never picked a color of their
    // own, and without it a light theme would open new terminals on the previous
    // theme's near-black. A color the user did choose is left exactly alone.
    //
    // Existing panes are moved by the window controllers (Pane.reapplyTheme),
    // which make the same comparison per pane; this covers the default that new
    // panes and new windows will start from.
    func startObservingThemeForDefaults() {
        NotificationCenter.default.addObserver(
            forName: Theme.didChange, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let previous = Theme.previousPalette(from: note) else { return }
            if Pane.sameColor(defaultTerminalBackground, previous.terminalBg) {
                defaultTerminalBackground = Theme.terminalBg
                saveSettings()
            } else if Pane.sameColor(defaultTerminalBackground, previous.bg) {
                defaultTerminalBackground = Theme.bg
                saveSettings()
            }
            // The Settings background well re-reads this on show(), so an open
            // window shows the retargeted value the next time it is opened —
            // deliberately not touched here, since reaching for the controller
            // would build the settings UI on a theme switch.

            // Then the terminal foreground, but on legibility rather than
            // equality: the shipped default is SwiftTerm's own near-white, which
            // never matched a theme token, so an equality test would leave white
            // text on a light theme's cream ground. Only a switch that would
            // actually swallow the text moves it — a color the user chose and can
            // still read is left alone.
            if !Self.isLegible(currentTextColor, on: defaultTerminalBackground) {
                textColorChanged(Theme.textPrimary)  // pushes to every pane + saves
            }
        }
    }

    // Rough WCAG contrast ratio between two opaque colors. Only used for the
    // "would this theme make the terminal unreadable?" test above, so the 2.5:1
    // floor is deliberately lenient — it catches white-on-cream, not a merely
    // low-contrast pairing someone picked on purpose.
    static func isLegible(_ text: NSColor, on background: NSColor) -> Bool {
        let a = relativeLuminance(text), b = relativeLuminance(background)
        let ratio = (max(a, b) + 0.05) / (min(a, b) + 0.05)
        return ratio >= 2.5
    }

    private static func relativeLuminance(_ color: NSColor) -> CGFloat {
        let c = color.usingColorSpace(.sRGB) ?? color
        func channel(_ v: CGFloat) -> CGFloat {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.redComponent)
            + 0.7152 * channel(c.greenComponent)
            + 0.0722 * channel(c.blueComponent)
    }

    // Like textColorChanged, the new default repaints every pane — including
    // ones with a per-pane menu override, which the user can re-pick.
    func defaultBackgroundChanged(_ color: NSColor) {
        defaultTerminalBackground = color
        for controller in windowControllers {
            controller.applyDefaultBackground(color)
        }
        saveSettings()
    }

    func cursorStyleChanged(_ style: CursorStyle) {
        cursorStyle = style
        for controller in windowControllers {
            controller.applyCursorStyle(style)
        }
        saveSettings()
    }
}
