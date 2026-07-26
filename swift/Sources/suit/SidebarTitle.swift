import Cocoa

// The title band every sidebar tab opens with — "FILES", "SEARCH", "SOURCE
// CONTROL", "SESSIONS", "SSH HOSTS", "NOTES", "BOOKMARKS".
//
// The Search tab has carried a caption like this since it split off the file
// tree, and the tabs written after it drifted: Notes, SSH and Bookmarks
// captioned themselves (each restating the same three type attributes), while
// Files, Source Control and Sessions announced nothing at all. That reads as an
// oversight rather than restraint — the activity bar beside the panel shows
// icons only, so a tab's own title is the only thing that confirms where a click
// on the strip landed. Every tab now carries one, from here.
//
// The size is deliberately a step above `Theme.captionFont`: this is a heading
// for the whole panel, not a label on a row inside it, and at caption size it
// disappeared into the content below it.
enum SidebarTitle {
    // One height for every tab, so the content under the title starts on the
    // same line whichever tab is showing. Tabs with header actions (Search's
    // toolbar, the + on Notes and SSH Hosts, the Files header's buttons) put
    // them on this row rather than taking a second one.
    static let height: CGFloat = 28

    // The title's left edge. Panel-level chrome, so it sits at the sidebar's own
    // margin rather than lining up with whatever the tab's first row indents to.
    static let leftInset: CGFloat = 10

    static func attributed(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: Theme.sidebarTitleFont,
            .foregroundColor: Theme.textFaint,
            .kern: Theme.sidebarTitleKern,
        ])
    }

    static func label(_ text: String) -> SidebarTitleLabel {
        SidebarTitleLabel(text)
    }
}

// A tab title that repaints itself on a theme switch.
//
// The colour is part of the attributed string, so the window controller's
// recursive needsDisplay sweep — which only reaches draw()-based chrome — cannot
// touch it: a title set once at init keeps the *outgoing* palette's grey until
// the next launch, which is exactly the caching-a-token bug the theme system
// warns about. Search and Source Control re-set theirs from a reapplyTheme();
// Notes, SSH Hosts and Bookmarks never did. Observing Theme.didChange here fixes
// all seven at once and means a new tab gets it for free.
final class SidebarTitleLabel: NSTextField {
    private let title: String

    init(_ title: String) {
        self.title = title
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBezeled = false
        isBordered = false
        drawsBackground = false
        attributedStringValue = SidebarTitle.attributed(title)
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged), name: Theme.didChange, object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func themeChanged() {
        attributedStringValue = SidebarTitle.attributed(title)
    }
}
