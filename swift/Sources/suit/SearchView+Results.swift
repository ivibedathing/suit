import Cocoa

// The results outline's data source and delegate. Two shapes over the same
// nodes: the default file tree (a SearchFileGroup per file, its matches as
// children) and the flat list the toolbar's ☰ switches to, where every match is
// a root row and carries its own file name. Only this file knows which shape is
// live — SearchView owns both arrays and keeps them in step as rg streams in.
extension SearchView {
    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if isFlatList { return item == nil ? flatMatches.count : 0 }
        guard let group = item as? SearchFileGroup else { return groups.count }
        return group.matches.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if isFlatList { return flatMatches[index] }
        guard let group = item as? SearchFileGroup else { return groups[index] }
        return group.matches[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !isFlatList && item is SearchFileGroup
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
            // Rebound on every configure: a recycled row still holds the closures
            // of whichever file it showed last.
            view.onReplace = { [weak self] in self?.replaceInFile(group) }
            view.onDismiss = { [weak self] in self?.dismissGroup(group) }
            return view
        }
        if let node = item as? SearchMatchNode {
            let identifier = NSUserInterfaceItemIdentifier("searchMatchRow")
            let view = outlineView.makeView(withIdentifier: identifier, owner: self) as? SearchMatchRowView ?? {
                let created = SearchMatchRowView(frame: .zero)
                created.identifier = identifier
                return created
            }()
            // The tree draws an indent guide down the file's children; in list
            // mode there is no parent to guide back to, so the row names its
            // file instead.
            view.configure(with: node, showsFile: isFlatList)
            return view
        }
        return nil
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        ThemedTableRowView()
    }
}
