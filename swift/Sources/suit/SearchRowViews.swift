import Cocoa

// A file header row: name, grayed parent directory, right-aligned match count.
final class SearchFileRowView: NSTableCellView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let directoryLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(nameLabel)

        directoryLabel.font = .systemFont(ofSize: 10)
        directoryLabel.textColor = Theme.textFaint
        directoryLabel.lineBreakMode = .byTruncatingHead
        addSubview(directoryLabel)

        countLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        countLabel.textColor = Theme.textDim
        countLabel.alignment = .center
        countLabel.wantsLayer = true
        countLabel.layer?.backgroundColor = Theme.hover.cgColor
        countLabel.layer?.cornerRadius = 3
        addSubview(countLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let countWidth = countLabel.intrinsicContentSize.width + 10
        countLabel.frame = NSRect(x: bounds.width - countWidth - 4, y: (bounds.height - 14) / 2, width: countWidth, height: 14)
        let nameWidth = min(nameLabel.intrinsicContentSize.width, bounds.width - countWidth - 14)
        nameLabel.frame = NSRect(x: 2, y: (bounds.height - 16) / 2, width: max(0, nameWidth), height: 16)
        let directoryX = nameLabel.frame.maxX + 6
        directoryLabel.frame = NSRect(
            x: directoryX,
            y: (bounds.height - 14) / 2,
            width: max(0, bounds.width - directoryX - countWidth - 10),
            height: 14
        )
    }

    func configure(with group: SearchFileGroup) {
        nameLabel.stringValue = (group.relativePath as NSString).lastPathComponent
        let directory = (group.relativePath as NSString).deletingLastPathComponent
        directoryLabel.stringValue = directory
        countLabel.stringValue = " \(group.matches.count) "
        needsLayout = true
    }
}

// A match row: line number in the gutter color, then the line's text with the
// matched ranges emphasized.
final class SearchMatchRowView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 2, y: (bounds.height - 16) / 2, width: max(0, bounds.width - 6), height: 16)
    }

    func configure(with node: SearchMatchNode) {
        let match = node.match
        // Trim leading indentation so deeply-nested code doesn't push the
        // match itself out of the truncated row.
        let trimmed = match.lineText.drop(while: { $0 == " " || $0 == "\t" })
        let trimOffset = match.lineText.utf16.count - trimmed.utf16.count
        let snippet = String(trimmed.prefix(300))

        let text = NSMutableAttributedString(
            string: "\(match.lineNumber)  ",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: Theme.textFaint,
            ]
        )
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
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
                .foregroundColor: Theme.textPrimary,
                .backgroundColor: Theme.accent.withAlphaComponent(0.25),
            ], range: shifted)
        }
        label.attributedStringValue = text
        needsLayout = true
    }
}
