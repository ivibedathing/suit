import Cocoa
import PDFKit

// PDF preview tab (ROADMAP Phase 19): a PDFKit PDFView with a page-thumbnail
// rail down the left. Scroll, page navigation, selection/copy — all read-only,
// so reviewing a design PDF or a spec doesn't mean a trip to Preview.app.
final class PDFPaneContent: NSObject, FileBackedPaneContent {
    weak var pane: Pane?
    weak var tab: Tab?

    private let containerView = NSView(frame: .zero)
    private let pdfView = PDFView(frame: .zero)
    private let thumbnailView = PDFThumbnailView(frame: .zero)
    private let statusLabel = NSTextField(labelWithString: "")

    private static let thumbnailWidth: CGFloat = 90
    private static let headerHeight: CGFloat = 0

    private(set) var filePath: String?
    private var background = Theme.terminalBg

    var view: NSView { containerView }
    var focusTarget: NSView { pdfView }
    var defaultTitle: String { "PDF" }
    var workingDirectory: String? {
        filePath.map { ($0 as NSString).deletingLastPathComponent }
    }
    var initialBackgroundColor: NSColor { background }

    override init() {
        super.init()

        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = Theme.terminalBg
        containerView.addSubview(pdfView)

        thumbnailView.pdfView = pdfView
        thumbnailView.thumbnailSize = NSSize(width: 70, height: 90)
        thumbnailView.backgroundColor = Theme.barChrome
        containerView.addSubview(thumbnailView)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = Theme.textDim
        statusLabel.alignment = .center
        statusLabel.isHidden = true
        containerView.addSubview(statusLabel)

        containerView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(layoutContents),
            name: NSView.frameDidChangeNotification, object: containerView
        )
    }

    func load(path: String, line: Int?) {
        let standardized = (path as NSString).standardizingPath
        filePath = standardized
        if let document = PDFDocument(url: URL(fileURLWithPath: standardized)) {
            pdfView.document = document
            pdfView.isHidden = false
            thumbnailView.isHidden = document.pageCount <= 1
            statusLabel.isHidden = true
        } else {
            pdfView.document = nil
            pdfView.isHidden = true
            thumbnailView.isHidden = true
            statusLabel.stringValue = "Could not open PDF."
            statusLabel.isHidden = false
        }
        tab?.contentTitleDidChange((standardized as NSString).lastPathComponent)
    }

    @objc private func layoutContents() {
        let bounds = containerView.bounds
        let showThumbs = !thumbnailView.isHidden
        let railWidth = showThumbs ? Self.thumbnailWidth : 0
        thumbnailView.frame = NSRect(x: 0, y: 0, width: railWidth, height: bounds.height)
        pdfView.frame = NSRect(x: railWidth, y: 0, width: max(0, bounds.width - railWidth), height: bounds.height)
        statusLabel.frame = NSRect(x: 0, y: bounds.midY - 10, width: bounds.width, height: 20)
    }

    // MARK: - State restoration (ROADMAP Phase 19)

    var currentPageIndex: Int {
        guard let document = pdfView.document, let page = pdfView.currentPage else { return 0 }
        return document.index(for: page)
    }

    func restore(pageIndex: Int) {
        guard let document = pdfView.document, pageIndex > 0, pageIndex < document.pageCount,
              let page = document.page(at: pageIndex) else { return }
        pdfView.go(to: page)
    }

    // MARK: - Appearance

    func applyBackground(_ color: NSColor) {
        background = color
        pdfView.backgroundColor = color
    }

    func teardown() {
        NotificationCenter.default.removeObserver(self)
    }
}
