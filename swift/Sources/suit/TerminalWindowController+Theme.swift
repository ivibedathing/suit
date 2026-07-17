import Cocoa

// Live theme apply (Stage 3 of shareable themes). ThemeStore.apply swaps
// Theme.current and posts Theme.didChange; each window controller observes it
// and repaints its whole world in one place — the same centralized-observer
// design as the derived focus border (one writer, no pushed state). No relaunch
// is needed for a switch to take full effect.
extension TerminalWindowController {

    // Registered once from init, torn down in windowWillClose (see +Closing).
    func startObservingTheme() {
        themeObserver = NotificationCenter.default.addObserver(
            forName: Theme.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.applyTheme()
        }
    }

    // Re-skin everything the new palette touches:
    //  - the window ground and each pane's container / header / tab-bar chrome
    //    and (for non-terminal panes) content background, via Pane.reapplyTheme;
    //  - each tab's content-internal color caches (background tabs included);
    //  - the sidebar rail;
    //  - every draw()-based chrome view, by forcing a recursive repaint (they
    //    read their tokens live at draw time), plus the file-viewer gutters;
    //  - the focus border, repainted from the actual first responder (the same
    //    single-writer path a focus change uses).
    func applyTheme() {
        window.backgroundColor = Theme.bg

        for pane in panes {
            pane.reapplyTheme()
        }
        // Background tabs aren't in any pane, so reach their content directly.
        for tab in store.tabs {
            tab.content.reapplyTheme()
        }

        sidebar.reapplyTheme()
        activityBar.reapplyTheme()

        if let root = window.contentView {
            refreshThemeRecursively(root)
        }

        let focused = focusedPane()
        for pane in panes {
            pane.setFocused(pane === focused)
        }
    }

    // Repaints the whole view subtree (draw()-based chrome re-reads Theme.* at
    // draw time) and refreshes the file-viewer line-number gutter, which is a
    // ruler on the scroll view rather than a plain subview.
    private func refreshThemeRecursively(_ view: NSView) {
        view.needsDisplay = true
        if let scroll = view as? NSScrollView,
           let ruler = scroll.verticalRulerView as? LineNumberRulerView {
            ruler.reapplyTheme()
        }
        for subview in view.subviews {
            refreshThemeRecursively(subview)
        }
    }
}
