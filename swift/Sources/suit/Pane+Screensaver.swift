import Cocoa

// MARK: - Screensaver
//
// The decorative ASCII overlay and its customization menus. Split out of
// Pane.swift; the customization state (font color, size, background, speed)
// lives on Pane itself because setScreensaver(_:) builds a fresh overlay view
// every time the kind changes.
extension Pane {
    func screensaverMenu() -> NSMenu {
        let menu = NSMenu()

        let noneItem = NSMenuItem(title: "None", action: #selector(pickScreensaver(_:)), keyEquivalent: "")
        noneItem.target = self
        noneItem.state = screensaverView == nil ? .on : .off
        menu.addItem(noneItem)

        menu.addItem(.separator())

        for kind in [PaneScreensaverKind.waves, .stars, .matrix] {
            let item = NSMenuItem(title: kind.rawValue, action: #selector(pickScreensaver(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind
            item.state = (screensaverView?.kind == kind) ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let fontColorItem = NSMenuItem(title: "Font Color", action: nil, keyEquivalent: "")
        fontColorItem.submenu = screensaverFontColorMenu()
        menu.addItem(fontColorItem)

        let fontSizeItem = NSMenuItem(title: "Font Size", action: nil, keyEquivalent: "")
        fontSizeItem.submenu = screensaverFontSizeMenu()
        menu.addItem(fontSizeItem)

        let backgroundColorItem = NSMenuItem(title: "Background Color", action: nil, keyEquivalent: "")
        backgroundColorItem.submenu = screensaverBackgroundColorMenu()
        menu.addItem(backgroundColorItem)

        let transparencyItem = NSMenuItem(title: "Transparency", action: nil, keyEquivalent: "")
        transparencyItem.submenu = screensaverTransparencyMenu()
        menu.addItem(transparencyItem)

        let speedItem = NSMenuItem(title: "Speed", action: nil, keyEquivalent: "")
        speedItem.submenu = screensaverSpeedMenu()
        menu.addItem(speedItem)

        return menu
    }

    @objc private func pickScreensaver(_ sender: NSMenuItem) {
        setScreensaver(sender.representedObject as? PaneScreensaverKind)
    }

    private func setScreensaver(_ kind: PaneScreensaverKind?) {
        screensaverView?.stop()
        guard let kind else {
            container.setScreensaverView(nil)
            screensaverView = nil
            return
        }
        let overlay = PaneScreensaverView(frame: .zero)
        overlay.kind = kind
        overlay.fontColor = screensaverFontColor
        overlay.fontSize = screensaverFontSize
        overlay.backgroundColor = screensaverBackgroundColor
        overlay.backgroundAlpha = screensaverBackgroundAlpha
        overlay.speed = screensaverSpeed
        container.setScreensaverView(overlay)
        overlay.start()
        screensaverView = overlay
    }

    // MARK: - Screensaver customization

    private func screensaverFontColorMenu() -> NSMenu {
        let menu = NSMenu()
        for (name, color) in Pane.screensaverFontColors {
            let item = NSMenuItem(title: name, action: #selector(pickScreensaverFontColor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = color
            item.image = Pane.swatchImage(for: color)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let customItem = NSMenuItem(title: "Custom Color…", action: #selector(openScreensaverFontColorPanel(_:)), keyEquivalent: "")
        customItem.target = self
        menu.addItem(customItem)
        return menu
    }

    @objc private func pickScreensaverFontColor(_ sender: NSMenuItem) {
        guard let color = sender.representedObject as? NSColor else { return }
        setScreensaverFontColor(color)
    }

    @objc private func openScreensaverFontColorPanel(_ sender: Any?) {
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(screensaverFontColorPanelChanged(_:)))
        panel.color = screensaverFontColor
        panel.showsAlpha = false
        panel.orderFront(nil)
    }

    @objc private func screensaverFontColorPanelChanged(_ sender: NSColorPanel) {
        setScreensaverFontColor(sender.color)
    }

    private func setScreensaverFontColor(_ color: NSColor) {
        screensaverFontColor = color
        screensaverView?.fontColor = color
    }

    private func screensaverBackgroundColorMenu() -> NSMenu {
        let menu = NSMenu()
        for (name, color) in Pane.presetColors {
            let item = NSMenuItem(title: name, action: #selector(pickScreensaverBackgroundColor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = color
            item.image = Pane.swatchImage(for: color)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let customItem = NSMenuItem(title: "Custom Color…", action: #selector(openScreensaverBackgroundColorPanel(_:)), keyEquivalent: "")
        customItem.target = self
        menu.addItem(customItem)
        return menu
    }

    @objc private func pickScreensaverBackgroundColor(_ sender: NSMenuItem) {
        guard let color = sender.representedObject as? NSColor else { return }
        setScreensaverBackgroundColor(color)
    }

    @objc private func openScreensaverBackgroundColorPanel(_ sender: Any?) {
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(screensaverBackgroundColorPanelChanged(_:)))
        panel.color = screensaverBackgroundColor
        panel.showsAlpha = false
        panel.orderFront(nil)
    }

    @objc private func screensaverBackgroundColorPanelChanged(_ sender: NSColorPanel) {
        setScreensaverBackgroundColor(sender.color)
    }

    private func setScreensaverBackgroundColor(_ color: NSColor) {
        screensaverBackgroundColor = color
        screensaverView?.backgroundColor = color
    }

    private func screensaverFontSizeMenu() -> NSMenu {
        let menu = NSMenu()
        for (name, size) in Pane.screensaverFontSizes {
            let item = NSMenuItem(title: name, action: #selector(pickScreensaverFontSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = size
            item.state = screensaverFontSize == size ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func pickScreensaverFontSize(_ sender: NSMenuItem) {
        guard let size = sender.representedObject as? CGFloat else { return }
        screensaverFontSize = size
        screensaverView?.fontSize = size
    }

    private func screensaverTransparencyMenu() -> NSMenu {
        let menu = NSMenu()
        for (name, alpha) in Pane.screensaverTransparencies {
            let item = NSMenuItem(title: name, action: #selector(pickScreensaverTransparency(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = alpha
            item.state = screensaverBackgroundAlpha == alpha ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func pickScreensaverTransparency(_ sender: NSMenuItem) {
        guard let alpha = sender.representedObject as? CGFloat else { return }
        screensaverBackgroundAlpha = alpha
        screensaverView?.backgroundAlpha = alpha
    }

    private func screensaverSpeedMenu() -> NSMenu {
        let menu = NSMenu()
        for (name, speed) in Pane.screensaverSpeeds {
            let item = NSMenuItem(title: name, action: #selector(pickScreensaverSpeed(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = speed
            item.state = screensaverSpeed == speed ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func pickScreensaverSpeed(_ sender: NSMenuItem) {
        guard let speed = sender.representedObject as? CGFloat else { return }
        screensaverSpeed = speed
        screensaverView?.speed = speed
    }
}
