import Cocoa

// The two row kinds in the Search tab's results outline.
//
// Both compute their hover state inside layout(), from the window's current
// mouse location, rather than latching it in mouseEntered/mouseExited. Rows are
// recycled constantly while rg streams results in, and a latched flag follows
// the *view* to whichever file it is reused for — leaving the replace and
// dismiss buttons showing on a row the pointer is nowhere near. The tracking
// area's only job here is to ask for a re-layout when the pointer moves.

// A file header row: type icon, name, grayed parent directory, and — on hover —
// the per-file replace and dismiss actions in place of the match count.
final class SearchFileRowView: NSTableCellView {
    // Called by the outline delegate on every configure; a recycled row still
    // holds the previous file's closures until it is rebound. Both nil means the
    // row has no actions to reveal — which is how the references pane, the other
    // user of these views, keeps its plain match-count rows.
    var onReplace: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let iconView = NSImageView(frame: .zero)
    private let nameLabel = NSTextField(labelWithString: "")
    private let directoryLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let replaceButton = NSButton(frame: .zero)
    private let dismissButton = NSButton(frame: .zero)

    private var isHovered = false
    // The file name's width, measured from the string in configure().
    // NSTextField.intrinsicContentSize is not usable here: on a label that
    // truncates, it reports the width the label *currently* has, so laying the
    // row out from it ratchets the name narrower every pass until the middle of
    // every filename is an ellipsis.
    private var nameWidth: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(nameLabel)

        directoryLabel.font = .systemFont(ofSize: 10)
        directoryLabel.lineBreakMode = .byTruncatingHead
        addSubview(directoryLabel)

        countLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        countLabel.alignment = .center
        countLabel.wantsLayer = true
        countLabel.layer?.cornerRadius = 3
        addSubview(countLabel)

        configure(action: replaceButton, symbol: "arrow.left.arrow.right",
                  tooltip: "Replace All in File", selector: #selector(replaceClicked))
        configure(action: dismissButton, symbol: "xmark",
                  tooltip: "Dismiss from results", selector: #selector(dismissClicked))

        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configure(action button: NSButton, symbol: String, tooltip: String, selector: Selector) {
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .medium))
        button.toolTip = tooltip
        button.target = self
        button.action = selector
        button.refusesFirstResponder = true
        button.isHidden = true
        addSubview(button)
    }

    @objc private func replaceClicked() { onReplace?() }
    @objc private func dismissClicked() { onDismiss?() }

    override func mouseEntered(with event: NSEvent) { needsLayout = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { needsLayout = true; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovered else { return }
        Theme.hover.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).fill()
    }

    override func layout() {
        super.layout()
        isHovered = hovered(in: self)

        let icon: CGFloat = 13
        iconView.frame = NSRect(x: 2, y: (bounds.height - icon) / 2, width: icon, height: icon)

        var right = bounds.width - 4
        let showsActions = isHovered && (onReplace != nil || onDismiss != nil)
        replaceButton.isHidden = !showsActions
        dismissButton.isHidden = !showsActions
        countLabel.isHidden = showsActions
        if showsActions {
            for button in [dismissButton, replaceButton] {
                right -= 18
                button.frame = NSRect(x: right, y: (bounds.height - 16) / 2, width: 18, height: 16)
            }
            right -= 4
        } else {
            let countWidth = countLabel.intrinsicContentSize.width + 8
            right -= countWidth
            countLabel.frame = NSRect(x: right, y: (bounds.height - 14) / 2, width: countWidth, height: 14)
            right -= 4
        }

        let left = iconView.frame.maxX + 6
        // The name takes what it needs and the directory gets the rest: a path
        // is the thing worth losing characters off, a filename isn't.
        let shownName = min(nameWidth, max(0, right - left))
        nameLabel.frame = NSRect(x: left, y: (bounds.height - 16) / 2, width: shownName, height: 16)
        let directoryX = nameLabel.frame.maxX + 6
        directoryLabel.frame = NSRect(
            x: directoryX, y: (bounds.height - 14) / 2,
            width: max(0, right - directoryX), height: 14
        )
    }

    func configure(with group: SearchFileGroup) {
        let name = (group.relativePath as NSString).lastPathComponent
        nameLabel.stringValue = name
        nameLabel.textColor = Theme.textPrimary
        // +6 for the cell's own inset: a label handed exactly its text width
        // still draws an ellipsis, which is the difference between "SearchView.swift"
        // and "Search…w.swift".
        nameWidth = ceil((name as NSString).size(withAttributes: [.font: nameLabel.font as Any]).width) + 6
        directoryLabel.stringValue = (group.relativePath as NSString).deletingLastPathComponent
        directoryLabel.textColor = Theme.textFaint
        countLabel.stringValue = "\(group.matches.count)"
        countLabel.textColor = Theme.textDim
        countLabel.layer?.backgroundColor = Theme.hover.cgColor
        for button in [replaceButton, dismissButton] {
            button.contentTintColor = Theme.textDim
        }
        // The Files tree's per-extension icon, so a result set is scannable by
        // the same colors the tree taught you.
        let (image, tint) = FileTreeIcon.image(for: FileNode(name: name, relativePath: group.relativePath,
                                                             isDirectory: false))
        iconView.image = image
        iconView.contentTintColor = tint
        toolTip = group.relativePath
        needsLayout = true
    }
}

// A match row: the line's text with the matched ranges emphasized, the line
// number parked faintly at the trailing edge, and an indent guide running down
// the left so a long run of hits reads as belonging to one file. In list mode
// the file name leads the row instead of the guide, because there is no header
// row above it to have named the file.
final class SearchMatchRowView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let lineLabel = NSTextField(labelWithString: "")

    private var isHovered = false
    private var drawsGuide = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        addSubview(label)

        lineLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        lineLabel.alignment = .right
        addSubview(lineLabel)

        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseEntered(with event: NSEvent) { needsLayout = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { needsLayout = true; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            Theme.hover.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).fill()
        }
        guard drawsGuide else { return }
        // Full-bleed vertically so consecutive matches join into one line rather
        // than a dashed column of stubs.
        Theme.hairline.setFill()
        NSRect(x: 1, y: 0, width: 1, height: bounds.height).fill()
    }

    override func layout() {
        super.layout()
        isHovered = hovered(in: self)
        let lineWidth: CGFloat = 34
        lineLabel.frame = NSRect(x: max(0, bounds.width - lineWidth - 4), y: (bounds.height - 13) / 2,
                                 width: lineWidth, height: 13)
        let left: CGFloat = drawsGuide ? 10 : 4
        label.frame = NSRect(x: left, y: (bounds.height - 16) / 2,
                             width: max(0, lineLabel.frame.minX - 4 - left), height: 16)
    }

    func configure(with node: SearchMatchNode, showsFile: Bool = false) {
        let match = node.match
        drawsGuide = !showsFile
        lineLabel.stringValue = "\(match.lineNumber)"
        lineLabel.textColor = Theme.textFaint

        // Trim leading indentation so deeply-nested code doesn't push the
        // match itself out of the truncated row.
        let trimmed = match.lineText.drop(while: { $0 == " " || $0 == "\t" })
        let trimOffset = match.lineText.utf16.count - trimmed.utf16.count
        let snippet = String(trimmed.prefix(300))

        let text = NSMutableAttributedString()
        if showsFile {
            text.append(NSAttributedString(
                string: (match.relativePath as NSString).lastPathComponent + "  ",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: Theme.textFaint,
                ]
            ))
        }
        let snippetStart = text.length
        text.append(NSAttributedString(
            string: snippet,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: Theme.textDim,
            ]
        ))
        let snippetLength = (snippet as NSString).length
        for range in match.matchRanges {
            let shifted = NSRange(location: range.location - trimOffset + snippetStart, length: range.length)
            guard shifted.location >= snippetStart,
                  shifted.location + shifted.length <= snippetStart + snippetLength else { continue }
            text.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: Theme.textPrimary,
                .backgroundColor: Theme.selection,
            ], range: shifted)
        }
        label.attributedStringValue = text
        toolTip = "\(match.relativePath):\(match.lineNumber)"
        needsLayout = true
        needsDisplay = true
    }
}

// Whether the pointer is currently inside this row. Read at layout time rather
// than tracked, for the reuse reason at the top of this file; outside a window
// (offscreen renders, the design harness) nothing is hovered.
private func hovered(in view: NSView) -> Bool {
    guard let window = view.window, window.isKeyWindow else { return false }
    let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
    return view.bounds.contains(point)
}
