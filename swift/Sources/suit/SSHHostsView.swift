import Cocoa

// An SSH host list row: display name plus the dimmed user@host:port · auth line.
private final class SSHHostRowView: NSTableCellView {
    static let height: CGFloat = 38

    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = Theme.textPrimary
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        detailLabel.font = .systemFont(ofSize: 10)
        detailLabel.textColor = Theme.textFaint
        detailLabel.lineBreakMode = .byTruncatingTail
        addSubview(detailLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        titleLabel.frame = NSRect(x: 8, y: bounds.height - 21, width: max(0, bounds.width - 16), height: 15)
        detailLabel.frame = NSRect(x: 8, y: bounds.height - 35, width: max(0, bounds.width - 16), height: 13)
    }

    func configure(host: SSHHost) {
        titleLabel.stringValue = host.displayName
        detailLabel.stringValue = host.detail
        toolTip = sshCommand(for: host)
        needsLayout = true
    }
}

// The sidebar's SSH Hosts tab: saved destinations, one click from a connected
// terminal tab. Add via "+", edit/delete via right-click; passwords never live
// here (or in the store) — only in the Keychain via SSHHostFormController's
// save path.
final class SSHHostsView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private static let headerHeight: CGFloat = 26

    // Receives the clicked host; the window controller opens the SSH tab.
    var onConnect: ((SSHHost) -> Void)?

    private let headerLabel = NSTextField(labelWithString: "")
    private let addButton = NSButton(frame: .zero)
    private let scrollView = NSScrollView(frame: .zero)
    private let tableView = NSTableView(frame: .zero)
    private let emptyLabel = NSTextField(
        wrappingLabelWithString: "No SSH hosts yet.\n\nClick + to save a host. Connecting opens a terminal tab; passwords are stored in the macOS Keychain."
    )

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        headerLabel.attributedStringValue = NSAttributedString(
            string: "SSH HOSTS",
            attributes: [
                .font: Theme.captionFont,
                .foregroundColor: Theme.textFaint,
                .kern: Theme.captionKern,
            ]
        )
        addSubview(headerLabel)

        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New SSH Host")
        addButton.isBordered = false
        addButton.bezelStyle = .regularSquare
        addButton.contentTintColor = Theme.textDim
        addButton.toolTip = "New SSH Host"
        addButton.target = self
        addButton.action = #selector(addHostClicked)
        addSubview(addButton)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sshHost"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.style = .sourceList
        tableView.dataSource = self
        tableView.delegate = self
        // Single click connects (Files-tab semantics); selection-change is not
        // used so arrow-keying through the list can't spawn tabs.
        tableView.target = self
        tableView.action = #selector(rowClicked)

        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        addSubview(scrollView)

        emptyLabel.alignment = .center
        emptyLabel.textColor = Theme.textFaint
        emptyLabel.font = .systemFont(ofSize: 11)
        addSubview(emptyLabel)

        NotificationCenter.default.addObserver(
            self, selector: #selector(storeChanged),
            name: SSHHostsStore.didUpdate, object: nil
        )
        storeChanged()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func layout() {
        super.layout()
        headerLabel.sizeToFit()
        headerLabel.frame.origin = NSPoint(x: 10, y: (Self.headerHeight - headerLabel.frame.height) / 2)
        addButton.frame = NSRect(x: bounds.width - 26, y: (Self.headerHeight - 18) / 2, width: 18, height: 18)
        scrollView.frame = NSRect(
            x: 0, y: Self.headerHeight,
            width: bounds.width, height: max(0, bounds.height - Self.headerHeight)
        )
        let labelHeight: CGFloat = 110
        emptyLabel.frame = NSRect(
            x: 12, y: (bounds.height - labelHeight) / 2,
            width: max(0, bounds.width - 24), height: labelHeight
        )
    }

    @objc private func storeChanged() {
        emptyLabel.isHidden = !SSHHostsStore.shared.hosts.isEmpty
        tableView.reloadData()
    }

    @objc private func addHostClicked() {
        SSHHostFormController.shared.show(host: nil, over: window) { host, newPassword in
            if let newPassword, host.auth == .password {
                SSHKeychain.setPassword(newPassword, forHostId: host.id)
            }
            SSHHostsStore.shared.add(host)
        }
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        let hosts = SSHHostsStore.shared.hosts
        guard row >= 0, row < hosts.count else { return }
        onConnect?(hosts[row])
    }

    // MARK: - Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard row >= 0, row < SSHHostsStore.shared.hosts.count else { return }
        let id = SSHHostsStore.shared.hosts[row].id
        for (title, action) in [
            ("Connect", #selector(connectFromMenu(_:))),
            ("Edit…", #selector(editFromMenu(_:))),
            ("Delete", #selector(deleteFromMenu(_:))),
        ] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = id
        }
    }

    private func host(from sender: NSMenuItem) -> SSHHost? {
        (sender.representedObject as? UUID).flatMap { SSHHostsStore.shared.host(withId: $0) }
    }

    @objc private func connectFromMenu(_ sender: NSMenuItem) {
        guard let host = host(from: sender) else { return }
        onConnect?(host)
    }

    @objc private func editFromMenu(_ sender: NSMenuItem) {
        guard let host = host(from: sender) else { return }
        SSHHostFormController.shared.show(host: host, over: window) { updated, newPassword in
            if updated.auth == .password {
                if let newPassword {
                    SSHKeychain.setPassword(newPassword, forHostId: updated.id)
                }
            } else {
                // Switched to key auth: the stored password is now orphaned.
                SSHKeychain.deletePassword(forHostId: updated.id)
            }
            SSHHostsStore.shared.update(updated)
        }
    }

    @objc private func deleteFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        SSHHostsStore.shared.delete(id: id)
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        SSHHostsStore.shared.hosts.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        SSHHostRowView.height
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let hosts = SSHHostsStore.shared.hosts
        guard row < hosts.count else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("sshHostRow")
        let view = tableView.makeView(withIdentifier: identifier, owner: self) as? SSHHostRowView ?? {
            let created = SSHHostRowView(frame: .zero)
            created.identifier = identifier
            return created
        }()
        view.configure(host: hosts[row])
        return view
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ThemedTableRowView()
    }
}

// The add/edit form on the overlay surface (OverlayPrompt's panel language,
// multi-field). Enter saves, Esc cancels, clicking elsewhere dismisses. The
// password travels only through onSave's `newPassword` argument — the caller
// writes it to the Keychain; the secure field is cleared on dismiss.
final class SSHHostFormController: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    static let shared = SSHHostFormController()

    private final class PromptPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    private static let panelSize = NSSize(width: 440, height: 296)

    private let panel: PromptPanel
    private let captionLabel = NSTextField(labelWithString: "")
    private let nameField = NSTextField(frame: .zero)
    private let hostField = NSTextField(frame: .zero)
    private let userField = NSTextField(frame: .zero)
    private let portField = NSTextField(frame: .zero)
    private let authPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let passwordField = NSSecureTextField(frame: .zero)
    private let optionsField = NSTextField(frame: .zero)

    private var editingHost: SSHHost?
    private var onSave: ((SSHHost, String?) -> Void)?

    override init() {
        panel = PromptPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false

        super.init()

        panel.delegate = self

        let surface = FlippedView(frame: NSRect(origin: .zero, size: Self.panelSize))
        surface.wantsLayer = true
        surface.layer?.backgroundColor = Theme.overlay.cgColor
        surface.layer?.cornerRadius = Theme.Metrics.overlayRadius
        surface.layer?.borderWidth = 1
        surface.layer?.borderColor = Theme.hairline.cgColor
        surface.layer?.masksToBounds = true
        surface.autoresizingMask = [.width, .height]
        panel.contentView = surface

        captionLabel.font = Theme.captionFont
        captionLabel.textColor = Theme.textFaint
        captionLabel.frame = NSRect(x: 18, y: 14, width: Self.panelSize.width - 36, height: 14)
        surface.addSubview(captionLabel)

        authPopup.addItems(withTitles: ["SSH key / agent", "Password"])
        authPopup.font = .systemFont(ofSize: 12)
        authPopup.isBordered = false
        authPopup.target = self
        authPopup.action = #selector(authChanged)

        var y: CGFloat = 40
        for (label, control) in [
            ("Name", nameField),
            ("Host", hostField),
            ("User", userField),
            ("Port", portField),
            ("Auth", authPopup as NSControl),
            ("Password", passwordField),
            ("Options", optionsField),
        ] {
            let rowLabel = NSTextField(labelWithString: label)
            rowLabel.font = .systemFont(ofSize: 11)
            rowLabel.textColor = Theme.textDim
            rowLabel.alignment = .right
            rowLabel.frame = NSRect(x: 18, y: y + 5, width: 72, height: 15)
            surface.addSubview(rowLabel)

            control.frame = NSRect(x: 100, y: y, width: Self.panelSize.width - 118, height: 26)
            if let field = control as? NSTextField {
                field.font = .systemFont(ofSize: 13)
                field.isBordered = false
                field.isBezeled = false
                field.focusRingType = .none
                field.textColor = Theme.textPrimary
                field.drawsBackground = true
                field.backgroundColor = Theme.bg
                field.wantsLayer = true
                field.layer?.cornerRadius = 5
                field.delegate = self
            }
            surface.addSubview(control)
            y += 34
        }

        // Tab order: top to bottom.
        nameField.nextKeyView = hostField
        hostField.nextKeyView = userField
        userField.nextKeyView = portField
        portField.nextKeyView = authPopup
        authPopup.nextKeyView = passwordField
        passwordField.nextKeyView = optionsField
        optionsField.nextKeyView = nameField

        hostField.placeholderString = "example.com (required)"
        userField.placeholderString = "root"
        portField.placeholderString = "22"
        optionsField.placeholderString = "extra ssh options, e.g. -i ~/.ssh/work"
    }

    // Pass nil to create; the saved host (never its password) to edit.
    func show(host: SSHHost?, over window: NSWindow?,
              onSave: @escaping (_ host: SSHHost, _ newPassword: String?) -> Void) {
        editingHost = host
        self.onSave = onSave

        captionLabel.stringValue = host == nil ? "NEW SSH HOST" : "EDIT SSH HOST"
        nameField.stringValue = host?.name ?? ""
        hostField.stringValue = host?.host ?? ""
        userField.stringValue = host?.user ?? ""
        portField.stringValue = host?.port.map(String.init) ?? ""
        authPopup.selectItem(at: host?.auth == .password ? 1 : 0)
        passwordField.stringValue = ""
        passwordField.placeholderString =
            host?.auth == .password ? "unchanged — leave blank to keep" : ""
        authChanged()

        if let window {
            let frame = window.frame
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - Self.panelSize.width / 2,
                y: frame.maxY - frame.height * 0.32 - Self.panelSize.height
            ))
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(host == nil ? nameField : hostField)
    }

    @objc private func authChanged() {
        let isPassword = authPopup.indexOfSelectedItem == 1
        passwordField.isEnabled = isPassword
        passwordField.alphaValue = isPassword ? 1 : 0.4
    }

    private func dismiss() {
        onSave = nil
        editingHost = nil
        passwordField.stringValue = ""
        panel.orderOut(nil)
    }

    private func commit() {
        let host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else {
            NSSound.beep()
            panel.makeFirstResponder(hostField)
            return
        }
        let portText = portField.stringValue.trimmingCharacters(in: .whitespaces)
        var port: Int?
        if !portText.isEmpty {
            guard let value = Int(portText), (1...65535).contains(value) else {
                NSSound.beep()
                panel.makeFirstResponder(portField)
                return
            }
            port = value
        }

        let user = userField.stringValue.trimmingCharacters(in: .whitespaces)
        let options = optionsField.stringValue.trimmingCharacters(in: .whitespaces)
        let entry = SSHHost(
            id: editingHost?.id ?? UUID(),
            name: nameField.stringValue.trimmingCharacters(in: .whitespaces),
            host: host,
            user: user.isEmpty ? nil : user,
            port: port,
            auth: authPopup.indexOfSelectedItem == 1 ? .password : .key,
            extraOptions: options.isEmpty ? nil : options
        )
        let newPassword = passwordField.stringValue.isEmpty ? nil : passwordField.stringValue
        let save = onSave
        dismiss()
        save?(entry, newPassword)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            commit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
            return true
        default:
            return false
        }
    }

    // Clicking elsewhere cancels, like the palette.
    func windowDidResignKey(_ notification: Notification) {
        dismiss()
    }
}
