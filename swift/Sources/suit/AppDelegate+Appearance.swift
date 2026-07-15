import Cocoa

// The visual settings verbs: the ⌘]/⌘[ opacity and ⇧⌘B blur shortcuts, word
// wrap, and the font/color/cursor `…Changed` handlers that apply a new value
// live across every window. Behavior toggles live in AppDelegate+Settings;
// persistence for both is AppDelegate+SettingsPersistence.
extension AppDelegate {
    // MARK: - Opacity & blur

    @objc func increaseOpacity(_ sender: Any?) {
        opacityChanged(min(1, backgroundAlpha + opacityStep))
    }

    @objc func decreaseOpacity(_ sender: Any?) {
        opacityChanged(max(minOpacity, backgroundAlpha - opacityStep))
    }

    @objc func toggleBlur(_ sender: Any?) {
        blurChanged(!blurEnabled)
    }

    func opacityChanged(_ value: CGFloat) {
        backgroundAlpha = value
        applyGlassToAllWindows()
        saveSettings()
    }

    func blurChanged(_ enabled: Bool) {
        blurEnabled = enabled
        applyGlassToAllWindows()
        saveSettings()
    }

    func blurRadiusChanged(_ radius: CGFloat) {
        blurRadius = min(maxBlurRadius, max(0, radius))
        applyGlassToAllWindows()
        saveSettings()
    }

    private func applyGlassToAllWindows() {
        for controller in windowControllers {
            controller.applyTransparency(
                alpha: backgroundAlpha, blurEnabled: blurEnabled, blurRadius: blurRadius
            )
        }
    }

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
