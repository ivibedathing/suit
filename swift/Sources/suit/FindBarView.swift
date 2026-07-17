import Cocoa

// The file viewer's find/replace widget: the VS Code-shaped bar that floats over
// the top-right of the text while ⌘F is open.
//
// Chrome follows OverlayPrompt (rounded Theme.overlay surface, hairline border)
// and the controls follow TimeTravelBarView (small textured buttons, manual
// layout, closure callbacks) — this owns no find logic at all. It reports what
// the user typed and clicked; FileViewerPane+Find decides what that means and
// calls back with a status to render. The matching itself is FindReplace.swift.
//
// Layout is two rows — find, then replace — with the replace row collapsed until
// the user asks for it (⌥⌘F, or the disclosure chevron), so plain ⌘F stays a
// one-line bar the way it is in VS Code.
final class FindBarView: NSView {
    // The disclosure chevron that shows/hides the replace row.
    private let disclosureButton = NSButton(title: "", target: nil, action: nil)
    private let findField = NSTextField(string: "")
    private let replaceField = NSTextField(string: "")
    private let caseButton = NSButton(title: "Aa", target: nil, action: nil)
    private let wordButton = NSButton(title: "ab", target: nil, action: nil)
    private let regexButton = NSButton(title: ".*", target: nil, action: nil)
    private let countLabel = NSTextField(labelWithString: "")
    private let previousButton = NSButton(title: "‹", target: nil, action: nil)
    private let nextButton = NSButton(title: "›", target: nil, action: nil)
    private let closeButton = NSButton(title: "✕", target: nil, action: nil)
    private let replaceButton = NSButton(title: "Replace", target: nil, action: nil)
    private let replaceAllButton = NSButton(title: "All", target: nil, action: nil)

    // Fired on every keystroke in either field and on every toggle — find is
    // incremental, like the stock bar and like VS Code.
    var onQueryChange: (() -> Void)?
    var onStep: ((_ forward: Bool) -> Void)?
    var onReplace: (() -> Void)?
    var onReplaceAll: (() -> Void)?
    var onClose: (() -> Void)?

    private static let rowHeight: CGFloat = 22
    private static let padding: CGFloat = 8
    private static let gap: CGFloat = 6
    static let preferredWidth: CGFloat = 460

    // Whether the replace row is showing. Setting it re-lays-out and asks the
    // container to re-position, since the bar's height changes.
    var isReplaceVisible = false {
        didSet {
            guard isReplaceVisible != oldValue else { return }
            replaceField.isHidden = !isReplaceVisible
            replaceButton.isHidden = !isReplaceVisible
            replaceAllButton.isHidden = !isReplaceVisible
            disclosureButton.title = isReplaceVisible ? "⌄" : "›"
            needsLayout = true
            superview?.needsLayout = true
            (superview as? ViewerContainerView)?.repositionFindOverlay()
        }
    }

    // Replace is gated on the buffer actually being writable: time-travel
    // revisions and the binary/too-large placeholders are read-only, and find
    // must keep working in all of them. Re-checked whenever those modes toggle,
    // not just when the bar opens.
    var canReplace = true {
        didSet {
            replaceField.isEnabled = canReplace
            replaceButton.isEnabled = canReplace
            replaceAllButton.isEnabled = canReplace
            replaceField.placeholderString = canReplace ? "Replace" : "Read-only"
        }
    }

    var query: FindQuery {
        FindQuery(text: findField.stringValue,
                  caseSensitive: caseButton.state == .on,
                  wholeWord: wordButton.state == .on,
                  regex: regexButton.state == .on)
    }

    var replacementTemplate: String { replaceField.stringValue }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.overlay.cgColor
        layer?.cornerRadius = Theme.Metrics.overlayRadius
        layer?.borderWidth = 1
        layer?.borderColor = Theme.hairline.cgColor
        layer?.masksToBounds = true

        disclosureButton.title = "›"
        disclosureButton.bezelStyle = .inline
        disclosureButton.isBordered = false
        disclosureButton.font = .systemFont(ofSize: 11, weight: .semibold)
        disclosureButton.contentTintColor = Theme.textDim
        disclosureButton.target = self
        disclosureButton.action = #selector(disclosureClicked)
        addSubview(disclosureButton)

        for field in [findField, replaceField] {
            field.font = .systemFont(ofSize: 11)
            field.controlSize = .small
            field.isBezeled = true
            field.bezelStyle = .roundedBezel
            field.focusRingType = .none
            field.delegate = self
            addSubview(field)
        }
        findField.placeholderString = "Find"
        replaceField.placeholderString = "Replace"

        // The three VS Code toggles. Push-on-push-off so their state reads at a
        // glance, and they re-run the search the moment they flip.
        for button in [caseButton, wordButton, regexButton] {
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .texturedRounded
            button.controlSize = .small
            button.font = .monospacedSystemFont(ofSize: 9, weight: .semibold)
            button.target = self
            button.action = #selector(toggleChanged)
            addSubview(button)
        }
        caseButton.toolTip = "Match case"
        wordButton.toolTip = "Match whole word"
        regexButton.toolTip = "Use regular expression"

        countLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        countLabel.textColor = Theme.textFaint
        countLabel.alignment = .right
        countLabel.lineBreakMode = .byTruncatingTail
        addSubview(countLabel)

        for button in [previousButton, nextButton] {
            button.bezelStyle = .texturedRounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11, weight: .medium)
            button.target = self
            addSubview(button)
        }
        previousButton.action = #selector(previousClicked)
        previousButton.toolTip = "Previous match (⇧⌘G)"
        nextButton.action = #selector(nextClicked)
        nextButton.toolTip = "Next match (⌘G)"

        closeButton.isBordered = false
        closeButton.font = .systemFont(ofSize: 10, weight: .medium)
        closeButton.contentTintColor = Theme.textDim
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = "Close (esc)"
        addSubview(closeButton)

        for button in [replaceButton, replaceAllButton] {
            button.bezelStyle = .texturedRounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.target = self
            addSubview(button)
        }
        replaceButton.action = #selector(replaceClicked)
        replaceAllButton.action = #selector(replaceAllClicked)
        replaceAllButton.toolTip = "Replace all"

        replaceField.isHidden = true
        replaceButton.isHidden = true
        replaceAllButton.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Key equivalents

    // ⌘G / ⇧⌘G / ⌘F / ⌥⌘F have to be caught here, not left to the menu.
    //
    // Menu key equivalents dispatch down the responder chain, and while the user
    // is typing in the find field the first responder is the field editor — an
    // NSTextView with no find bar of its own, which validates the find actions to
    // false. The Find menu would therefore beep for the entire time the bar is
    // open, which is precisely when these keys are wanted. The key window offers
    // key equivalents to its view hierarchy before the menu bar sees them, so
    // answering here works whichever field has focus.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        let shift = flags.contains(.shift)
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "g":
            onStep?(!shift)
            return true
        case "f" where flags.contains(.option):
            isReplaceVisible = true
            focusReplaceField()
            return true
        case "f" where !shift:
            // ⌘F with the bar already up re-targets it rather than opening a
            // second one: focus the query and select it, so typing replaces it.
            focusFindField()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    // MARK: - Driving from the pane

    // Seed the query text (⌘E / the current selection) without the caller having
    // to know about the field.
    func setQueryText(_ text: String) {
        findField.stringValue = text
    }

    func setReplacementText(_ text: String) {
        replaceField.stringValue = text
    }

    // Put the caret in the find field with the text selected, so a second ⌘F
    // types over the old query rather than appending to it.
    func focusFindField() {
        window?.makeFirstResponder(findField)
        findField.currentEditor()?.selectAll(nil)
    }

    func focusReplaceField() {
        window?.makeFirstResponder(replaceField)
        replaceField.currentEditor()?.selectAll(nil)
    }

    // The match readout: "3 of 17", "No results", or a bad-pattern warning.
    // Stepping is pointless with nothing to step to, so the arrows follow it.
    func showStatus(index: Int?, count: Int, invalidPattern: Bool) {
        if invalidPattern {
            countLabel.stringValue = "Bad pattern"
            countLabel.textColor = Theme.failed
        } else if query.isEmpty {
            countLabel.stringValue = ""
            countLabel.textColor = Theme.textFaint
        } else if count == 0 {
            countLabel.stringValue = "No results"
            countLabel.textColor = Theme.textFaint
        } else {
            countLabel.stringValue = "\((index ?? 0) + 1) of \(count)"
            countLabel.textColor = Theme.textDim
        }
        let canStep = !invalidPattern && count > 0
        previousButton.isEnabled = canStep
        nextButton.isEnabled = canStep
        replaceButton.isEnabled = canReplace && canStep
        replaceAllButton.isEnabled = canReplace && canStep
    }

    // MARK: - Actions

    @objc private func disclosureClicked() { isReplaceVisible.toggle() }
    @objc private func toggleChanged() { onQueryChange?() }
    @objc private func previousClicked() { onStep?(false) }
    @objc private func nextClicked() { onStep?(true) }
    @objc private func closeClicked() { onClose?() }
    @objc private func replaceClicked() { onReplace?() }
    @objc private func replaceAllClicked() { onReplaceAll?() }

    // MARK: - Layout

    // The bar sizes itself; the container only places it. Width is capped so it
    // stays a widget rather than stretching across a wide editor.
    func preferredSize(maxWidth: CGFloat) -> NSSize {
        let rows: CGFloat = isReplaceVisible ? 2 : 1
        let height = Self.padding * 2 + rows * Self.rowHeight + (rows - 1) * Self.gap
        return NSSize(width: min(Self.preferredWidth, max(0, maxWidth)), height: height)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let pad = Self.padding
        let row = Self.rowHeight
        let gap = Self.gap
        // Top row sits at the top; AppKit's origin is bottom-left, so the find
        // row's y depends on whether the replace row is below it.
        let findRowY = bounds.height - pad - row
        let replaceRowY = findRowY - gap - row

        let disclosureWidth: CGFloat = 14
        disclosureButton.frame = NSRect(x: pad, y: findRowY, width: disclosureWidth, height: row)

        // Right-hand cluster, laid out right-to-left: close, next, prev, count.
        let closeWidth: CGFloat = 18
        closeButton.frame = NSRect(x: bounds.width - pad - closeWidth, y: findRowY, width: closeWidth, height: row)

        let stepWidth: CGFloat = 24
        nextButton.frame = NSRect(x: closeButton.frame.minX - gap - stepWidth, y: findRowY, width: stepWidth, height: row)
        previousButton.frame = NSRect(x: nextButton.frame.minX - 2 - stepWidth, y: findRowY, width: stepWidth, height: row)

        let countWidth: CGFloat = 62
        countLabel.frame = NSRect(x: previousButton.frame.minX - gap - countWidth,
                                  y: findRowY + (row - 14) / 2, width: countWidth, height: 14)

        let toggleWidth: CGFloat = 24
        regexButton.frame = NSRect(x: countLabel.frame.minX - gap - toggleWidth, y: findRowY, width: toggleWidth, height: row)
        wordButton.frame = NSRect(x: regexButton.frame.minX - 2 - toggleWidth, y: findRowY, width: toggleWidth, height: row)
        caseButton.frame = NSRect(x: wordButton.frame.minX - 2 - toggleWidth, y: findRowY, width: toggleWidth, height: row)

        let fieldX = pad + disclosureWidth + gap
        findField.frame = NSRect(x: fieldX, y: findRowY,
                                 width: max(0, caseButton.frame.minX - gap - fieldX), height: row)

        guard isReplaceVisible else { return }

        let allWidth: CGFloat = 40
        replaceAllButton.frame = NSRect(x: bounds.width - pad - allWidth, y: replaceRowY, width: allWidth, height: row)
        let replaceWidth: CGFloat = 66
        replaceButton.frame = NSRect(x: replaceAllButton.frame.minX - gap - replaceWidth, y: replaceRowY,
                                     width: replaceWidth, height: row)
        replaceField.frame = NSRect(x: fieldX, y: replaceRowY,
                                    width: max(0, replaceButton.frame.minX - gap - fieldX), height: row)
    }
}

// MARK: - Field editing

extension FindBarView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        onQueryChange?()
    }

    // Return steps to the next match (⇧Return to the previous) and esc closes —
    // the same keys the stock find bar answers to, so the muscle memory carries
    // over. Return inside the replace field replaces instead, like VS Code.
    //
    // ⇧Return has to be read off the event: AppKit maps both Return and ⇧Return
    // to insertNewline: for a field editor, so the selector alone can't tell them
    // apart. (insertBacktab: is ⇧Tab, not ⇧Return — binding it here would step
    // matches while silently breaking reverse field navigation.)
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            let backward = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            if control === replaceField, !backward {
                onReplace?()
            } else {
                onStep?(!backward)
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }
}
