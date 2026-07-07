import Cocoa

extension TerminalWindowController {

    // MARK: - Pane drag & drop rearrangement

    private func pane(withDragID id: String) -> Pane? {
        panes.first { $0.dragID == id }
    }

    // Only drags that resolve to a *different* pane of *this* window are movable;
    // a drag from another window just isn't found here and is rejected.
    func canMovePane(withDragID id: String, onto target: Pane) -> Bool {
        guard let source = pane(withDragID: id) else { return false }
        return source !== target
    }

    func movePane(withDragID id: String, onto target: Pane, zone: PaneDropZone) -> Bool {
        guard let source = pane(withDragID: id), source !== target else { return false }

        switch zone {
        case .swap:
            swapPanes(source, target)
        case .left, .right, .top, .bottom:
            let orientation: SplitOrientation = (zone == .left || zone == .right) ? .vertical : .horizontal
            // Same usability floor as split(): refuse drops that would produce
            // unusably small panes. (Conservative: if source and target are
            // currently siblings, detaching would actually free up more room.)
            let available = orientation == .vertical ? target.container.frame.width : target.container.frame.height
            guard available >= (orientation == .vertical ? minPaneWidth : minPaneHeight) * 2 else {
                NSSound.beep()
                return false
            }
            // source !== target means at least two panes exist, so source's
            // container always sits inside a split.
            guard let parentSplit = source.container.superview as? NSSplitView else { return false }
            _ = detachFromPaneTree(source.container, parentSplit: parentSplit)
            insert(source.container, besides: target.container, orientation: orientation, before: zone == .left || zone == .top)
        }

        window.makeFirstResponder(source.focusTarget)
        return true
    }

    // Removes `view` from its parent split and collapses that split, promoting the
    // sibling into the slot the split occupied (splits always hold exactly two
    // arranged subviews). Returns the promoted sibling, or nil if there wasn't one.
    // `view` itself (and its pane) is left intact, so callers can dissolve the
    // pane or re-insert it elsewhere (footer docking, drag rearrangement).
    func detachFromPaneTree(_ view: NSView, parentSplit: NSSplitView) -> NSView? {
        guard let sibling = parentSplit.arrangedSubviews.first(where: { $0 !== view }) else {
            return nil
        }

        // sibling only ever held half of parentSplit's rect; now that it's taking over
        // the whole slot, it needs to be resized into the space parentSplit used to
        // occupy rather than keeping the smaller frame it had as one half of the split.
        let vacatedFrame = parentSplit.frame

        parentSplit.removeArrangedSubview(view)
        view.removeFromSuperview()
        parentSplit.removeArrangedSubview(sibling)
        sibling.removeFromSuperview()

        if parentSplit === paneTreeRoot {
            paneTreeHost.replaceSubview(parentSplit, with: sibling)
            paneTreeRoot = sibling
        } else if let grandparent = parentSplit.superview as? NSSplitView {
            let index = grandparent.arrangedSubviews.firstIndex(of: parentSplit) ?? 0
            grandparent.removeArrangedSubview(parentSplit)
            parentSplit.removeFromSuperview()
            grandparent.insertArrangedSubview(sibling, at: index)
        }
        sibling.frame = vacatedFrame
        return sibling
    }

    // Exchanges the two containers' positions in the split tree. Every pane
    // container sits inside an NSSplitView here — a swap needs two panes, so the
    // root can't be a bare container.
    private func swapPanes(_ a: Pane, _ b: Pane) {
        guard let parentA = a.container.superview as? NSSplitView,
              let parentB = b.container.superview as? NSSplitView,
              let indexA = parentA.arrangedSubviews.firstIndex(of: a.container),
              let indexB = parentB.arrangedSubviews.firstIndex(of: b.container) else { return }

        let frameA = a.container.frame
        let frameB = b.container.frame

        parentA.removeArrangedSubview(a.container)
        a.container.removeFromSuperview()
        parentB.removeArrangedSubview(b.container)
        b.container.removeFromSuperview()

        if parentA === parentB {
            // Same two-child split: re-add in flipped order.
            parentA.insertArrangedSubview(indexA < indexB ? b.container : a.container, at: 0)
            parentA.insertArrangedSubview(indexA < indexB ? a.container : b.container, at: 1)
        } else {
            parentA.insertArrangedSubview(b.container, at: indexA)
            parentB.insertArrangedSubview(a.container, at: indexB)
        }

        // Each container takes over the other's old rect so the surrounding
        // dividers stay exactly where they were.
        a.container.frame = frameB
        b.container.frame = frameA
    }
}
