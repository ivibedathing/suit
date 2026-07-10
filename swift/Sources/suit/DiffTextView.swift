import Cocoa

// A read-only diff text view that takes review-mode keys:
// n/p walk the changed files, o opens the current file in the viewer pane.
final class DiffTextView: NSTextView {
    weak var diffContent: DiffPaneContent?

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "n":
            diffContent?.navigateFiles(1)
        case "p":
            diffContent?.navigateFiles(-1)
        case "o":
            diffContent?.openCurrentFile()
        case "c":
            diffContent?.addCommentAtCaret()
        default:
            super.keyDown(with: event)
        }
    }
}
