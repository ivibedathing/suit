import Cocoa
import PDFKit

// PDF preview tab: a PDFKit PDFView with a page-thumbnail
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
    // Live reload: a spec re-exported, or a LaTeX/typst build rewriting its
    // output, refreshes the open tab on the page the reader is already on.
    private var fileWatcher: FileWatcher?
    private var fileStamp: FileStamp?

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
        readDocument(standardized)
        tab?.contentTitleDidChange((standardized as NSString).lastPathComponent)

        fileWatcher?.stop()
        fileWatcher = FileWatcher(path: standardized) { [weak self] in
            self?.reloadFromDisk()
        }
    }

    // Re-reading a PDF replaces the document wholesale, which resets the view to
    // page one — so callers that reload in place restore the page themselves.
    private func readDocument(_ standardized: String) {
        fileStamp = FileStamp(path: standardized)
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
    }

    private func reloadFromDisk() {
        guard let filePath, FileStamp.changed(from: fileStamp, to: FileStamp(path: filePath)) else { return }
        // Hold the reader's place across the swap. A rebuilt document that grew
        // or shrank may not have that page any more — restore(pageIndex:) is
        // already bounds-checked, so it just stays on page one in that case.
        let page = currentPageIndex
        readDocument(filePath)
        restore(pageIndex: page)
    }

    @objc private func layoutContents() {
        let bounds = containerView.bounds
        let showThumbs = !thumbnailView.isHidden
        let railWidth = showThumbs ? Self.thumbnailWidth : 0
        thumbnailView.frame = NSRect(x: 0, y: 0, width: railWidth, height: bounds.height)
        pdfView.frame = NSRect(x: railWidth, y: 0, width: max(0, bounds.width - railWidth), height: bounds.height)
        statusLabel.frame = NSRect(x: 0, y: bounds.midY - 10, width: bounds.width, height: 20)
    }

    // MARK: - State restoration

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

    // Live theme switch: re-tint the status label (baked once).
    func reapplyTheme() {
        statusLabel.textColor = Theme.textDim
    }

    func teardown() {
        NotificationCenter.default.removeObserver(self)
        fileWatcher?.stop()
        fileWatcher = nil
    }
}
