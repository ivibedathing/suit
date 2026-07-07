import Foundation

// The canonical list of the app's keyboard shortcuts, surfaced read-only in the
// Settings window's Docs tab (see SettingsWindowController). Kept in sync by
// hand with the menu built in AppDelegate.buildMenu(); README.md's "Keyboard
// shortcuts" section mirrors the same list. When you add or change a menu key
// equivalent, update this list too.
enum KeyboardShortcuts {
    struct Entry {
        let keys: String   // display form, e.g. "⇧⌘T"
        let title: String

        init(_ keys: String, _ title: String) {
            self.keys = keys
            self.title = title
        }
    }

    struct Group {
        let name: String
        let entries: [Entry]
        // A trailing note rendered dimmed under the group (e.g. contextual keys
        // that only apply in a particular pane).
        let note: String?

        init(_ name: String, _ entries: [Entry], note: String? = nil) {
            self.name = name
            self.entries = entries
            self.note = note
        }
    }

    static let groups: [Group] = [
        Group("Tabs", [
            Entry("⌘T", "New tab"),
            Entry("⌘W", "Close tab"),
            Entry("⇧⌘T", "Reopen closed tab"),
            Entry("⇧⌘]", "Next tab"),
            Entry("⇧⌘[", "Previous tab"),
            Entry("⌃Tab", "Cycle recent tabs (MRU)"),
            Entry("⌃⇧Tab", "Cycle recent tabs (back)"),
            Entry("⌘1…⌘8", "Go to tab 1–8"),
            Entry("⌘9", "Go to last tab"),
        ]),
        Group("Screens & splits", [
            Entry("⌘D", "Split screen with new terminal"),
            Entry("⇧⌘D", "Split screen horizontally (stacked)"),
            Entry("⌥⌘W", "Unsplit (keep tab)"),
            Entry("⌃⌘M", "Unsplit all"),
            Entry("⌥⌘←", "Focus split left"),
            Entry("⌥⌘→", "Focus split right"),
            Entry("⌥⌘↑", "Focus split above"),
            Entry("⌥⌘↓", "Focus split below"),
        ]),
        Group("Files, search & navigation", [
            Entry("⌘P", "Open quickly (fuzzy file finder)"),
            Entry("⌘K", "Command palette"),
            Entry("⌘B", "Toggle sidebar"),
            Entry("⇧⌘F", "Search in project"),
            Entry("⌘F", "Find in pane"),
            Entry("⌘G", "Find next"),
            Entry("⇧⌘G", "Find previous"),
            Entry("⌘E", "Use selection for find"),
            Entry("⌘L", "Go to line (file viewer)"),
        ]),
        Group("Git & Claude", [
            Entry("⌃⌘D", "Show git diff"),
            Entry("⌃⌘C", "New Claude session"),
            Entry("⌃⌘T", "New Claude task…"),
        ]),
        Group("Diff review", [
            Entry("n", "Next changed file"),
            Entry("p", "Previous changed file"),
            Entry("o", "Open file under review in viewer"),
        ], note: "Active while a diff pane is focused."),
        Group("Appearance", [
            Entry("⌘=", "Increase font size"),
            Entry("⌘-", "Decrease font size"),
            Entry("⇧⌘=", "Increase font size (all panes)"),
            Entry("⇧⌘-", "Decrease font size (all panes)"),
            Entry("⌘]", "Increase opacity"),
            Entry("⌘[", "Decrease opacity"),
            Entry("⇧⌘B", "Toggle background blur"),
        ]),
        Group("Editing", [
            Entry("⌘C", "Copy"),
            Entry("⌘V", "Paste"),
        ]),
        Group("App & windows", [
            Entry("⌘N", "New window"),
            Entry("⌘,", "Settings"),
            Entry("⌘Q", "Quit Suit"),
        ]),
    ]
}
