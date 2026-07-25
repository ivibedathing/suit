import Cocoa

// Every split in the window — the sidebar divider and the whole pane tree —
// drawn with the palette's hairline instead of AppKit's system divider.
//
// The system divider color comes from the *appearance*, not from the theme, and
// the window pins .darkAqua: on the darker palettes it lands within a couple of
// levels of `barChrome`, so the boundary between the sidebar and the pane tree
// (or between two stacked panes) simply isn't there to see. `dividerColor` is
// the supported hook — NSSplitView asks for it on every divider draw, so a
// computed override follows a live theme switch for free, with nothing cached
// and nothing to reapply.
final class SuitSplitView: NSSplitView {
    override var dividerColor: NSColor { Theme.hairline }
}
