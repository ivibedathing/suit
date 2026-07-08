import Cocoa

// The diff pane (ROADMAP Phase 3): renders `git diff` output side-by-side or
// unified. Heavy use comes in Phase 5's review mode - the pane is driven by
// diff *text* (see DiffParser.swift), so any producer can feed it.

// The diff pane: a header (mode toggle + refresh) above one unified text view
// or two side-by-side views with locked scrolling.
final class DiffPaneContent: NSObject, PaneContent {
    weak var pane: Pane?
    weak var tab: Tab?

    let containerView = NSView(frame: .zero)
    let modePicker = NSSegmentedControl(labels: ["Unified", "Side by Side"], trackingMode: .selectOne, target: nil, action: nil)
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    let reviewButton = NSButton(title: "Review", target: nil, action: nil)
    let statusLabel = NSTextField(labelWithString: "")

    // The review draft (ROADMAP Phase 16): comments accumulate here, render
    // inline in the unified view, and compose into one prompt sent to a session.
    let reviewDraft = DiffReviewDraft()

    // One entry per rendered content line of the *unified* view, mapping its
    // character range back to the diff line it came from — the hit-test behind
    // "add comment at caret" and the anchor comments render against.
    struct UnifiedLineRef {
        let range: NSRange
        let file: String
        let side: DiffReviewComment.Side
        let line: Int
        let text: String
    }
    var unifiedLineRefs: [UnifiedLineRef] = []

    let unifiedScroll = NSScrollView(frame: .zero)
    let unifiedText: DiffTextView
    let leftScroll = NSScrollView(frame: .zero)
    let leftText: DiffTextView
    let rightScroll = NSScrollView(frame: .zero)
    let rightText: DiffTextView

    var diffLines: [DiffLine] = []
    var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    var baseColor = NSColor.textColor
    private var background = Theme.bg
    var syncingScroll = false

    // Review walking (ROADMAP Phase 5): each changed file's path and where its
    // header sits in the rendered unified / side-by-side texts, in diff order.
    var changedFilePaths: [String] = []
    var unifiedAnchors: [Int] = []
    var sideAnchors: [Int] = []

    // Re-runs whatever produced the current diff (git diff on a root, a
    // review-set command, …); set by the loader.
    var reload: (() -> String)?
    var gitRoot: String?

    // Set while this diff tab is reviewing a GitHub PR (ROADMAP Phase 39): the
    // number + repo root "Submit Review" posts to, and the title for the compose
    // header. nil for an ordinary git-diff tab.
    struct ReviewingPR { let number: Int; let root: String; let title: String }
    var reviewingPR: ReviewingPR?

    var view: NSView { containerView }
    var focusTarget: NSView { modePicker.selectedSegment == 0 ? unifiedText : leftText }
    var defaultTitle: String { "Diff" }
    var workingDirectory: String? { gitRoot }

    var initialBackgroundColor: NSColor { background }

    override init() {
        unifiedText = DiffTextView(frame: .zero)
        leftText = DiffTextView(frame: .zero)
        rightText = DiffTextView(frame: .zero)
        super.init()

        for (textView, scroll) in [(unifiedText, unifiedScroll), (leftText, leftScroll), (rightText, rightScroll)] {
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.usesFindBar = true
            textView.textContainerInset = NSSize(width: 4, height: 4)
            textView.autoresizingMask = [.width]
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.textContainer?.widthTracksTextView = true
            textView.drawsBackground = true
            textView.diffContent = self
            scroll.documentView = textView
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            scroll.borderType = .noBorder
            containerView.addSubview(scroll)
        }

        modePicker.selectedSegment = 0
        modePicker.controlSize = .small
        modePicker.target = self
        modePicker.action = #selector(modeChanged)
        containerView.addSubview(modePicker)

        refreshButton.controlSize = .small
        refreshButton.bezelStyle = .texturedRounded
        refreshButton.target = self
        refreshButton.action = #selector(refresh)
        containerView.addSubview(refreshButton)

        // The review inspector's entry point: shown only once the draft has a
        // comment (ROADMAP Phase 16). Click pops the list + Send / Clear menu.
        reviewButton.controlSize = .small
        reviewButton.bezelStyle = .texturedRounded
        reviewButton.target = self
        reviewButton.action = #selector(showReviewMenu(_:))
        reviewButton.isHidden = true
        containerView.addSubview(reviewButton)

        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = Theme.textFaint
        statusLabel.lineBreakMode = .byTruncatingTail
        containerView.addSubview(statusLabel)

        containerView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(layoutContents),
            name: NSView.frameDidChangeNotification, object: containerView
        )

        // Locked side-by-side scrolling: whichever side moves drives the other.
        for scroll in [leftScroll, rightScroll] {
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(sideScrolled(_:)),
                name: NSView.boundsDidChangeNotification, object: scroll.contentView
            )
        }

        updateModeVisibility()
    }

    @objc func layoutContents() {
        let bounds = containerView.bounds
        let headerHeight: CGFloat = 30
        let contentHeight = max(0, bounds.height - headerHeight)

        modePicker.sizeToFit()
        modePicker.frame.origin = NSPoint(x: 8, y: contentHeight + (headerHeight - modePicker.frame.height) / 2)
        refreshButton.sizeToFit()
        refreshButton.frame.origin = NSPoint(x: bounds.width - refreshButton.frame.width - 8, y: contentHeight + (headerHeight - refreshButton.frame.height) / 2)

        var rightEdge = refreshButton.frame.minX
        if !reviewButton.isHidden {
            reviewButton.sizeToFit()
            reviewButton.frame.origin = NSPoint(x: rightEdge - reviewButton.frame.width - 6, y: contentHeight + (headerHeight - reviewButton.frame.height) / 2)
            rightEdge = reviewButton.frame.minX
        }

        let statusX = modePicker.frame.maxX + 10
        statusLabel.frame = NSRect(
            x: statusX, y: contentHeight + 8,
            width: max(0, rightEdge - statusX - 8), height: 14
        )

        unifiedScroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: contentHeight)
        let half = (bounds.width / 2).rounded(.down)
        leftScroll.frame = NSRect(x: 0, y: 0, width: half, height: contentHeight)
        rightScroll.frame = NSRect(x: half + 1, y: 0, width: max(0, bounds.width - half - 1), height: contentHeight)
    }

    // MARK: - Appearance

    func applyFont(_ newFont: NSFont) {
        font = newFont
        render()
    }

    func applyTextColor(_ color: NSColor) {
        baseColor = color
        render()
    }

    func applyBackground(_ color: NSColor) {
        background = color
        for textView in [unifiedText, leftText, rightText] {
            textView.backgroundColor = color
        }
    }

    func teardown() {
        NotificationCenter.default.removeObserver(self)
    }
}
