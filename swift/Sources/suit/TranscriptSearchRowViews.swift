import Cocoa

// MARK: - Outline nodes

// One session's worth of results. Equality follows sessionId so reloadData
// preserves expansion while batches stream in.
final class TranscriptGroupNode: NSObject {
    let info: TranscriptSessionInfo
    let transcriptPath: String
    var results: [TranscriptResultNode] = []

    init(info: TranscriptSessionInfo, transcriptPath: String) {
        self.info = info
        self.transcriptPath = transcriptPath
    }

    override func isEqual(_ object: Any?) -> Bool {
        (object as? TranscriptGroupNode)?.info.sessionId == info.sessionId
    }
    override var hash: Int { info.sessionId.hashValue }
}

final class TranscriptResultNode: NSObject {
    let result: TranscriptSearchResult
    init(result: TranscriptSearchResult) { self.result = result }
}

// MARK: - Row views

final class TranscriptGroupRowView: NSTableCellView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let cwdLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        return f
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        addSubview(nameLabel)

        cwdLabel.font = .systemFont(ofSize: 10)
        cwdLabel.textColor = Theme.textFaint
        cwdLabel.lineBreakMode = .byTruncatingHead
        addSubview(cwdLabel)

        dateLabel.font = .systemFont(ofSize: 10)
        dateLabel.textColor = Theme.textFaint
        dateLabel.alignment = .right
        addSubview(dateLabel)

        countLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        countLabel.textColor = Theme.textDim
        countLabel.alignment = .center
        countLabel.wantsLayer = true
        countLabel.layer?.backgroundColor = Theme.hover.cgColor
        countLabel.layer?.cornerRadius = 3
        addSubview(countLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let dateWidth: CGFloat = 92
        let countWidth = countLabel.intrinsicContentSize.width + 10
        countLabel.frame = NSRect(x: bounds.width - countWidth - 4, y: (bounds.height - 14) / 2, width: countWidth, height: 14)
        dateLabel.frame = NSRect(x: bounds.width - countWidth - dateWidth - 10, y: (bounds.height - 14) / 2, width: dateWidth, height: 14)
        let nameWidth = min(nameLabel.intrinsicContentSize.width, max(0, bounds.width - countWidth - dateWidth - 24))
        nameLabel.frame = NSRect(x: 4, y: (bounds.height - 16) / 2, width: max(0, nameWidth), height: 16)
        let cwdX = nameLabel.frame.maxX + 6
        cwdLabel.frame = NSRect(x: cwdX, y: (bounds.height - 14) / 2, width: max(0, bounds.width - cwdX - countWidth - dateWidth - 16), height: 14)
    }

    func configure(with group: TranscriptGroupNode) {
        nameLabel.stringValue = group.info.displayName
        cwdLabel.stringValue = group.info.cwd.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? ""
        dateLabel.stringValue = group.info.date == .distantPast ? "" : Self.dateFormatter.string(from: group.info.date)
        countLabel.stringValue = " \(group.results.count) "
        needsLayout = true
    }
}

final class TranscriptResultRowView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 4, y: (bounds.height - 16) / 2, width: max(0, bounds.width - 8), height: 16)
    }

    func configure(with node: TranscriptResultNode) {
        let result = node.result
        let text = NSMutableAttributedString(
            string: result.snippet,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: Theme.textDim,
            ]
        )
        let length = (result.snippet as NSString).length
        for range in result.matchRanges where range.location + range.length <= length {
            text.addAttributes([
                .font: NSFont.systemFont(ofSize: 11, weight: .bold),
                .foregroundColor: Theme.textPrimary,
                .backgroundColor: Theme.accent.withAlphaComponent(0.25),
            ], range: range)
        }
        label.attributedStringValue = text
        needsLayout = true
    }
}
