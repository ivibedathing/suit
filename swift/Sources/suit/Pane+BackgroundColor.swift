import Cocoa

// MARK: - Background color
//
// The pane background-color preset menu and color-panel actions. Split out of
// Pane.swift; the setters (setBackgroundColor/setBackgroundAlpha) stay in the
// primary declaration since they touch stored state.
extension Pane {
    func backgroundColorMenu() -> NSMenu {
        let menu = NSMenu()
        for (name, color) in Pane.presetColors {
            let item = NSMenuItem(title: name, action: #selector(pickBackgroundColor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = color
            item.image = Pane.swatchImage(for: color)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let customItem = NSMenuItem(title: "Custom Color…", action: #selector(openColorPanel(_:)), keyEquivalent: "")
        customItem.target = self
        menu.addItem(customItem)
        return menu
    }

    @objc private func pickBackgroundColor(_ sender: NSMenuItem) {
        guard let color = sender.representedObject as? NSColor else { return }
        setBackgroundColor(color)
    }

    @objc private func openColorPanel(_ sender: Any?) {
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        panel.color = backgroundRGB
        panel.showsAlpha = false
        panel.orderFront(nil)
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        setBackgroundColor(sender.color)
    }
}
