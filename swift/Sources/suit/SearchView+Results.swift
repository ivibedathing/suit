import Cocoa

extension SearchView {
    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let group = item as? SearchFileGroup else { return groups.count }
        return group.matches.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let group = item as? SearchFileGroup else { return groups[index] }
        return group.matches[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is SearchFileGroup
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let group = item as? SearchFileGroup {
            let identifier = NSUserInterfaceItemIdentifier("searchFileRow")
            let view = outlineView.makeView(withIdentifier: identifier, owner: self) as? SearchFileRowView ?? {
                let created = SearchFileRowView(frame: .zero)
                created.identifier = identifier
                return created
            }()
            view.configure(with: group)
            return view
        }
        if let node = item as? SearchMatchNode {
            let identifier = NSUserInterfaceItemIdentifier("searchMatchRow")
            let view = outlineView.makeView(withIdentifier: identifier, owner: self) as? SearchMatchRowView ?? {
                let created = SearchMatchRowView(frame: .zero)
                created.identifier = identifier
                return created
            }()
            view.configure(with: node)
            return view
        }
        return nil
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        ThemedTableRowView()
    }
}
