import Cocoa

// The strip above the Files tree (ROADMAP Phase 9): the browsed root's name
// on the left (pin icon when the root is pinned rather than following the
// focused pane), a folder-picker button on the right, and an unpin button
// while pinned.
final class RootHeaderView: NSView {
    static let height: CGFloat = 26

    var onChooseFolder: (() -> Void)?
    var onUnpin: (() -> Void)?

    private let separator = NSBox(frame: .zero)
    private let iconView = NSImageView(frame: .zero)
    private let nameLabel = NSTextField(labelWithString: "")
    private let chooseButton = NSButton(frame: .zero)
    private let unpinButton = NSButton(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        separator.boxType = .separator
        addSubview(separator)

        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = Theme.textDim
        addSubview(iconView)

        nameLabel.font = .systemFont(ofSize: 11, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(nameLabel)

        configure(button: chooseButton, symbol: "folder.badge.plus", tooltip: "Select Folder…", action: #selector(chooseFolder))
        configure(button: unpinButton, symbol: "pin.slash", tooltip: "Unpin — follow the focused pane again", action: #selector(unpin))
        unpinButton.isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configure(button: NSButton, symbol: String, tooltip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.toolTip = tooltip
        button.target = self
        button.action = action
        button.contentTintColor = Theme.textDim
        addSubview(button)
    }

    func update(rootPath: String, pinned: Bool) {
        nameLabel.stringValue = (rootPath as NSString).lastPathComponent
        nameLabel.toolTip = (rootPath as NSString).abbreviatingWithTildeInPath
        iconView.image = NSImage(systemSymbolName: pinned ? "pin.fill" : "folder", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .medium))
        iconView.contentTintColor = pinned ? Theme.accent : Theme.textDim
        unpinButton.isHidden = !pinned
        needsLayout = true
    }

    @objc private func chooseFolder() {
        onChooseFolder?()
    }

    @objc private func unpin() {
        onUnpin?()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        separator.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
        let padding: CGFloat = 8
        let buttonSize: CGFloat = 18
        var right = bounds.width - padding
        chooseButton.frame = NSRect(x: right - buttonSize, y: (bounds.height - buttonSize) / 2, width: buttonSize, height: buttonSize)
        right = chooseButton.frame.minX - 4
        if !unpinButton.isHidden {
            unpinButton.frame = NSRect(x: right - buttonSize, y: (bounds.height - buttonSize) / 2, width: buttonSize, height: buttonSize)
            right = unpinButton.frame.minX - 4
        }
        iconView.frame = NSRect(x: padding, y: (bounds.height - 12) / 2, width: 12, height: 12)
        let nameX = iconView.frame.maxX + 4
        nameLabel.frame = NSRect(x: nameX, y: (bounds.height - 15) / 2, width: max(0, right - nameX - 2), height: 15)
    }
}
