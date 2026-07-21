import Cocoa

// The inline definition popover (⌥⌘J, ⌥⌘-click, or Peek Definition from the
// context menu): a small syntax-coloured window onto the definition's source,
// floated over the text near the caret.
//
// Peek exists because most go-to-definition presses are questions, not
// journeys — "what does this take?", "is this the one that mutates?" — and
// answering them by opening a tab costs the reader their place. Peek answers in
// place and leaves on Esc, and promotes to a real jump with Return for the times
// the answer was "I need to be there".
final class DefinitionPeekView: NSView {
    // Return, or a click on the header — go to the definition properly.
    var onOpen: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let headerLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "esc to close · return to open")
    private let scrollView = NSScrollView()
    private let textView = NSTextView()

    // Enough to see a signature and the first few lines of a body; past this the
    // answer is "open it properly", which is what Return is for.
    static let maximumHeight: CGFloat = 210
    static let preferredWidth: CGFloat = 520
    private static let headerHeight: CGFloat = 24

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.overlay.cgColor
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = Theme.hairline.cgColor
        // A real shadow, because the whole point is that this floats *over* code
        // rather than being part of it.
        shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
            shadow.shadowBlurRadius = 14
            shadow.shadowOffset = NSSize(width: 0, height: -3)
            return shadow
        }()

        headerLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        headerLabel.textColor = Theme.textPrimary
        headerLabel.lineBreakMode = .byTruncatingHead
        addSubview(headerLabel)

        hintLabel.font = NSFont.systemFont(ofSize: 10)
        hintLabel.textColor = Theme.textFaint
        addSubview(hintLabel)

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Fill the popover: where the definition is, its source, and which line to
    // highlight as *the* declaration.
    func show(
        header: String,
        source: String,
        highlightedLineOffset: Int,
        font: NSFont,
        textColor: NSColor,
        spans: [SyntaxSpan]
    ) {
        headerLabel.stringValue = header
        textView.font = font
        textView.string = source
        textView.textColor = textColor

        guard let storage = textView.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.addAttribute(.font, value: font, range: full)
        storage.addAttribute(.foregroundColor, value: textColor, range: full)
        for span in spans where NSMaxRange(span.range) <= storage.length {
            storage.addAttribute(.foregroundColor, value: span.kind.color, range: span.range)
        }

        // The declaration line itself gets a wash, so a peek that shows a few
        // lines of context still says which one answered the question.
        let ns = source as NSString
        var lineStart = 0
        var lineEnd = 0
        var index = 0
        var line = 0
        while index <= ns.length, line <= highlightedLineOffset {
            var end = 0
            var contentsEnd = 0
            ns.getLineStart(&lineStart, end: &end, contentsEnd: &contentsEnd,
                            for: NSRange(location: min(index, ns.length), length: 0))
            lineEnd = end
            if line == highlightedLineOffset { break }
            guard end > index else { break }
            index = end
            line += 1
        }
        if lineEnd > lineStart, lineEnd <= ns.length {
            storage.addAttribute(.backgroundColor, value: Theme.accent.withAlphaComponent(0.16),
                                 range: NSRange(location: lineStart, length: lineEnd - lineStart))
        }
    }

    // The height this popover wants for its content, capped.
    func preferredHeight() -> CGFloat {
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let used = textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 0
        let content = used + textView.textContainerInset.height * 2
        return min(Self.maximumHeight, Self.headerHeight + max(40, content) + 2)
    }

    override func layout() {
        super.layout()
        headerLabel.frame = NSRect(x: 10, y: 5, width: max(0, bounds.width - 190), height: 15)
        hintLabel.frame = NSRect(x: bounds.width - 175, y: 6, width: 165, height: 14)
        scrollView.frame = NSRect(x: 1, y: Self.headerHeight,
                                  width: bounds.width - 2,
                                  height: max(0, bounds.height - Self.headerHeight - 1))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Theme.hairline.setFill()
        NSRect(x: 0, y: Self.headerHeight - 0.5, width: bounds.width, height: 0.5).fill()
    }

    override func mouseDown(with event: NSEvent) {
        // A click on the header bar promotes the peek to a real jump; a click in
        // the source is just selecting text.
        let point = convert(event.locationInWindow, from: nil)
        if point.y < Self.headerHeight { onOpen?() }
    }
}
