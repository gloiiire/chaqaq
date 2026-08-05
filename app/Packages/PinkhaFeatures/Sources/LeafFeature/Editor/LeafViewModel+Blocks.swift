import SwiftUI
import PinkhaFFI
import PinkhaCore

// ── Block management ──────────────────────────────────────────────────────────

public extension LeafViewModel {

    func addBlock(type: NewBlockType, initialSpans: [InlineTextFfi] = [], afterId: String? = nil, atStart: Bool = false) {
        do {
            let content: BlockContentFfi
            switch type {
            case .text:     content = .text([])
            case .title1:   content = .heading(level: 1, text: [])
            case .title2:   content = .heading(level: 2, text: [])
            case .title3:   content = .heading(level: 3, text: [])
            case .quote:    content = .quote(icon: "", text: [])
            case .callout:  content = .quote(icon: "💡", text: [])
            case .todo:     content = .todo(done: false, text: [])
            case .bulleted: content = .bulletedListItem([])
            case .numbered: content = .numberedListItem([])
            case .divider:  content = .divider
            }
            let data  = try JSONEncoder().encode(content)
            let newId = try api.addBlock(leafId: leafId,
                                         blockContentJson: String(decoding: data, as: UTF8.self))
            let newBlock = EditableBlock(id: newId, content: content, spans: initialSpans, done: false)

            if let afterId, let idx = blocks.firstIndex(where: { $0.id == afterId }) {
                blocks.insert(newBlock, at: idx + 1)
                try? api.reorderBlocks(leafId: leafId, order: blocks.map(\.id))
            } else if atStart {
                blocks.insert(newBlock, at: 0)
                try? api.reorderBlocks(leafId: leafId, order: blocks.map(\.id))
            } else {
                blocks.append(newBlock)
            }
            if !initialSpans.isEmpty { persistBlockRaw(newBlock) }
            blockSnapshots[newId] = snapshotOf(newBlock)
            autoFocusOffset = 0
            autoFocusId = newId
            // Undo: delete the just-created block. deleteBlock auto-registers the redo (reinsertion).
            undoMgr.registerUndo(withTarget: self) { vm in vm.deleteBlock(id: newId) }
        } catch { errorMessage = error.localizedDescription }
    }

    /// Inserts a `Page` block at the end of the leaf — used when a
    /// child leaf has been created from the bubble while this doc was on
    /// screen. Going through this method (instead of a direct FFI call)
    /// keeps `blocks`, `blockSnapshots` and the undo stack in sync, so
    /// the next burst flush doesn't overwrite the new block.
    func addChildLeafBlock(childLeafId: String) {
        do {
            let content = BlockContentFfi.leaf(id: childLeafId)
            let data    = try JSONEncoder().encode(content)
            let newId   = try api.addBlock(leafId: leafId,
                                           blockContentJson: String(decoding: data, as: UTF8.self))
            let newBlock = EditableBlock(id: newId, content: content, spans: [], done: false)
            blocks.append(newBlock)
            blockSnapshots[newId] = snapshotOf(newBlock)
            undoMgr.registerUndo(withTarget: self) { vm in vm.deleteBlock(id: newId) }
        } catch { errorMessage = error.localizedDescription }
    }

    /// Number of rows immediately after `index` that are descendants of the
    /// block at `index` — the contiguous run with a strictly greater depth.
    ///
    /// `blocks` is a *flattened* depth-first view of a tree Rust still owns
    /// as a real hierarchy, so a parent and its children are sibling rows
    /// here. Anything that removes a parent has to remove that run too.
    private func descendantRunLength(at index: Int) -> Int {
        let depth = blocks[index].depth
        var length = 0
        var cursor = index + 1
        while cursor < blocks.count, blocks[cursor].depth > depth {
            length += 1
            cursor += 1
        }
        return length
    }

    /// Rebuilds the real block tree from a contiguous run of flattened rows.
    ///
    /// `run[0]` is the subtree root and everything after it is a descendant,
    /// ordered depth-first — which is exactly how `flattenBlocks` produced
    /// them. Regrouping by depth reverses that flattening losslessly.
    private static func blockTree(from run: [EditableBlock]) -> BlockFfi {
        let root = run[0]
        var children: [BlockFfi] = []
        var cursor = 1
        while cursor < run.count {
            let childDepth = run[cursor].depth
            var end = cursor + 1
            while end < run.count, run[end].depth > childDepth { end += 1 }
            children.append(blockTree(from: Array(run[cursor..<end])))
            cursor = end
        }
        return BlockFfi(
            id: root.id,
            content: root.content.withSpans(root.spans, done: root.done),
            children: children,
            color: root.color,
            backgroundColor: root.backgroundColor,
            textDirection: root.textDirection
        )
    }

    /// Id of the block that owns the row at `index`, or `nil` at top level.
    /// The parent is the nearest preceding row one depth shallower.
    private func parentId(of index: Int) -> String? {
        let depth = blocks[index].depth
        guard depth > 0 else { return nil }
        var cursor = index - 1
        while cursor >= 0 {
            if blocks[cursor].depth == depth - 1 { return blocks[cursor].id }
            cursor -= 1
        }
        return nil
    }

    /// Position of the row at `index` among its siblings.
    private func siblingIndex(of index: Int) -> Int {
        let depth = blocks[index].depth
        var position = 0
        var cursor = index - 1
        while cursor >= 0 {
            let d = blocks[cursor].depth
            if d < depth { break }      // reached the parent
            if d == depth { position += 1 }
            cursor -= 1
        }
        return position
    }

    func deleteBlock(id: String) {
        flushBurst(blockId: id)
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        // Capture the tree position *before* deleting — afterwards the rows
        // are gone and the parent/sibling relationship can't be recovered.
        let parent = parentId(of: index)
        let sibling = siblingIndex(of: index)
        do {
            try api.deleteBlock(leafId: leafId, blockId: id)
            // Rust's `delete_from_tree` drops the block *and its whole
            // subtree*. Removing only this row would leave the children
            // rendered as orphans pointing at a block that no longer
            // exists — and typing into one would fail with `NotFound` and
            // silently discard the keystrokes.
            let runEnd = index + descendantRunLength(at: index)
            let removed = Array(blocks[index...runEnd])
            blocks.removeSubrange(index...runEnd)
            for block in removed { blockSnapshots.removeValue(forKey: block.id) }
            undoMgr.registerUndo(withTarget: self) { vm in
                vm.restoreBlockRun(removed, at: index, parentId: parent, siblingIndex: sibling)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    /// Undo of a delete: puts the whole subtree back where it was, with its
    /// ids, nesting and attributes intact, and registers the redo.
    ///
    /// Goes through `insert_block_tree` rather than `add_block` — the latter
    /// appends a bare `BlockContent` at the document root, so it could not
    /// express nesting, colour, background colour or writing direction, and
    /// undoing the deletion of a styled indented block used to bring it back
    /// flat and unstyled *and persist that*.
    private func restoreBlockRun(
        _ run: [EditableBlock],
        at index: Int,
        parentId parent: String?,
        siblingIndex sibling: Int
    ) {
        guard !run.isEmpty else { return }
        do {
            let tree = Self.blockTree(from: run)
            let data = try JSONEncoder().encode(tree)
            try api.insertBlockTree(
                leafId: leafId,
                blockJson: String(decoding: data, as: UTF8.self),
                parentId: parent,
                index: UInt32(sibling)
            )
            let at = min(index, blocks.count)
            blocks.insert(contentsOf: run, at: at)
            for block in run { blockSnapshots[block.id] = snapshotOf(block) }
            autoFocusOffset = nil
            autoFocusId = run[0].id
            // Redo: delete it again.
            undoMgr.registerUndo(withTarget: self) { vm in
                vm.deleteBlock(id: run[0].id)
            }
        } catch { errorMessage = error.localizedDescription }
    }


    func deleteBlocks(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        for id in ids { flushBurst(blockId: id) }

        // Only the *roots* of the selection matter. A selected block whose
        // ancestor is also selected is already covered by that ancestor's
        // subtree — deleting it separately would double-handle it, and
        // restoring it separately would duplicate it.
        var roots: [(index: Int, parent: String?, sibling: Int, run: [EditableBlock])] = []
        for (index, block) in blocks.enumerated() where ids.contains(block.id) {
            let covered = roots.contains { root in
                root.run.contains { $0.id == block.id } && root.run.first?.id != block.id
            }
            if covered { continue }
            let runEnd = index + descendantRunLength(at: index)
            roots.append((
                index: index,
                parent: parentId(of: index),
                sibling: siblingIndex(of: index),
                run: Array(blocks[index...runEnd])
            ))
        }

        // Deepest first. Deleting a parent also deletes its subtree on the
        // Rust side, so a shallower id processed first makes every selected
        // descendant vanish — and the next `deleteBlock` for one of them
        // throws `NotFound`. `ids` is a Set, so the old iteration order was
        // unspecified: whether the user's delete worked was a coin flip.
        let ordered = roots.sorted { ($0.run.first?.depth ?? 0) > ($1.run.first?.depth ?? 0) }

        var failure: Error?
        for root in ordered {
            guard let id = root.run.first?.id else { continue }
            do {
                try api.deleteBlock(leafId: leafId, blockId: id)
            } catch {
                // A block already removed as part of an ancestor's subtree
                // is the expected case, not an error — keep going.
                if !isNotFound(error) { failure = error }
            }
        }

        // Apply the in-memory removal and register undo unconditionally.
        // Bailing out mid-loop used to leave the deleted rows on screen
        // while they were already gone from SQLite, so any later keystroke
        // in one of them was silently discarded.
        let removedIds = Set(roots.flatMap { $0.run.map(\.id) })
        blocks.removeAll { removedIds.contains($0.id) }
        for id in removedIds { blockSnapshots.removeValue(forKey: id) }
        undoMgr.registerUndo(withTarget: self) { vm in
            vm.undoMgr.beginUndoGrouping()
            // Ascending index so each restore lands before the next one's
            // position is computed.
            for root in roots.sorted(by: { $0.index < $1.index }) {
                vm.restoreBlockRun(root.run,
                                   at: root.index,
                                   parentId: root.parent,
                                   siblingIndex: root.sibling)
            }
            vm.undoMgr.endUndoGrouping()
        }
        if let failure { errorMessage = failure.localizedDescription }
    }

    /// Whether an FFI error is a `NotFound`, which several bulk paths treat
    /// as success (the row was already gone).
    private func isNotFound(_ error: Error) -> Bool {
        if case PinkhaError.NotFound = error { return true }
        return false
    }

    /// Toggles the "done" state of a todo block. Undo toggles it back (auto-re-registration).
    func toggleBlockDone(id: String) {
        guard let idx = blocks.firstIndex(where: { $0.id == id }) else { return }
        blocks[idx].done.toggle()
        persistBlock(blocks[idx])
        undoMgr.registerUndo(withTarget: self) { vm in vm.toggleBlockDone(id: id) }
    }

    /// Updates the emoji icon of a callout block. Undo restores the previous icon.
    func updateBlockIcon(id: String, icon: String) {
        guard let idx = blocks.firstIndex(where: { $0.id == id }) else { return }
        guard case .quote(let oldIcon, _) = blocks[idx].content, oldIcon != icon else { return }
        blocks[idx].content = .quote(icon: icon, text: blocks[idx].spans)
        persistBlock(blocks[idx])
        undoMgr.registerUndo(withTarget: self) { vm in
            vm.updateBlockIcon(id: id, icon: oldIcon)
        }
    }

    /// Converts a block's content (markdown shortcut: text → heading, etc.).
    /// Undo restores the previous content + spans; redo re-applies the conversion.
    func convertBlockContent(id: String, to newContent: BlockContentFfi) {
        guard let idx = blocks.firstIndex(where: { $0.id == id }) else { return }
        let oldContent = blocks[idx].content
        let oldSpans = blocks[idx].spans
        let oldDone = blocks[idx].done
        blocks[idx].content = newContent
        // Carry over the spans embedded in `newContent` so a "Change
        // to" conversion from the context menu keeps the user's text.
        // Markdown shortcuts pass spans=[] here too (the coordinator
        // builds the new content with the stripped text), so this
        // matches both call sites.
        blocks[idx].spans = newContent.spansOrEmpty
        blocks[idx].done = false
        persistBlock(blocks[idx])
        undoMgr.registerUndo(withTarget: self) { vm in
            guard let i = vm.blocks.firstIndex(where: { $0.id == id }) else { return }
            vm.blocks[i].content = oldContent
            vm.blocks[i].spans = oldSpans
            vm.blocks[i].done = oldDone
            vm.persistBlock(vm.blocks[i])
            vm.undoMgr.registerUndo(withTarget: vm) { vm in
                vm.convertBlockContent(id: id, to: newContent)
            }
        }
    }

    func startNavigationRepeat(from: String, next: Bool) {
        guard !repeater.active else { return }
        focusedBlockId = from
        repeater.start { [weak self] in self?.navigationStep(next: next) }
    }

    func stopNavigationRepeat() {
        repeater.stop()
        focusedBlockId = nil
    }

    private func navigationStep(next: Bool) {
        guard let cid = focusedBlockId,
              let idx = blocks.firstIndex(where: { $0.id == cid }) else { stopNavigationRepeat(); return }
        if next {
            guard idx < blocks.count - 1 else { stopNavigationRepeat(); return }
            let nid = blocks[idx + 1].id
            autoFocusOffset = 0; focusedBlockId = nid; autoFocusId = nid
        } else {
            guard idx > 0 else { stopNavigationRepeat(); return }
            let nid = blocks[idx - 1].id
            autoFocusOffset = nil; focusedBlockId = nid; autoFocusId = nid
        }
    }

    func moveBlock(from: IndexSet, to: Int) {
        let oldOrder = blocks.map(\.id)
        blocks.move(fromOffsets: from, toOffset: to)
        let newOrder = blocks.map(\.id)
        guard oldOrder != newOrder else { return }
        try? api.reorderBlocks(leafId: leafId, order: newOrder)
        undoMgr.registerUndo(withTarget: self) { vm in vm.applyBlockOrder(oldOrder) }
    }

    /// iOS 27 reorderable handler: applies a `ReorderDifference` produced by
    /// SwiftUI's new `.reorderable()` / `.reorderContainer(for:)` pair and
    /// funnels through the same reorder + undo path as `moveBlock`. The diff
    /// carries a set of source IDs and a `.before(targetID)` or `.end`
    /// destination — we rebuild the new order list-side and delegate.
    @available(iOS 27.0, *)
    func moveBlocks(applyingDifference diff: ReorderDifference<String, ReorderableSingleCollectionIdentifier>) {
        let oldOrder = blocks.map(\.id)
        let sources = Set(diff.sources)
        var newOrder = oldOrder.filter { !sources.contains($0) }
        switch diff.destination.position {
        case .before(let targetId):
            if let idx = newOrder.firstIndex(of: targetId) {
                newOrder.insert(contentsOf: diff.sources, at: idx)
            } else {
                newOrder.append(contentsOf: diff.sources)
            }
        case .end:
            newOrder.append(contentsOf: diff.sources)
        }
        guard newOrder != oldOrder else { return }
        let lookup = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
        blocks = newOrder.compactMap { lookup[$0] }
        try? api.reorderBlocks(leafId: leafId, order: newOrder)
        undoMgr.registerUndo(withTarget: self) { vm in vm.applyBlockOrder(oldOrder) }
    }

    /// Applies a block order (used by undo/redo of moveBlock).
    private func applyBlockOrder(_ order: [String]) {
        let oldOrder = blocks.map(\.id)
        let lookup = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
        blocks = order.compactMap { lookup[$0] }
        try? api.reorderBlocks(leafId: leafId, order: order)
        undoMgr.registerUndo(withTarget: self) { vm in vm.applyBlockOrder(oldOrder) }
    }

    /// Indents the given block — moves it under the previous sibling at the
    /// same level. The tree shape changes (not just the order), so we reload
    /// the full leaf from SQLite afterwards.
    ///
    /// `InvalidOperation` from the FFI (block is the first of its level —
    /// nothing to indent under) surfaces via `errorMessage` like any other
    /// error; the UI uses `.errorAlert` to show it.
    func indentBlock(id: String) {
        flushAllBursts()
        do {
            try api.indentBlock(leafId: leafId, blockId: id)
            reloadBlocksAfterStructuralChange()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Outdents the given block — moves it up to its grandparent level,
    /// inserted right after the former parent. Same reload semantics as
    /// `indentBlock`.
    func outdentBlock(id: String) {
        flushAllBursts()
        do {
            try api.outdentBlock(leafId: leafId, blockId: id)
            reloadBlocksAfterStructuralChange()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Applies (or clears with `nil`) the per-block writing direction.
    /// Mutates the in-memory `EditableBlock` so the editor re-orients
    /// immediately, then persists via the FFI. Registers the inverse
    /// on the UndoManager.
    func setBlockTextDirection(id: String, direction: String?) {
        guard let idx = blocks.firstIndex(where: { $0.id == id }) else { return }
        let previous = blocks[idx].textDirection
        guard previous != direction else { return }
        blocks[idx].textDirection = direction
        do {
            try api.setBlockTextDirection(leafId: leafId, blockId: id, textDirection: direction)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        undoMgr.registerUndo(withTarget: self) { vm in
            vm.setBlockTextDirection(id: id, direction: previous)
        }
    }

    /// Applies (or clears with `nil`) the block-level *background* color
    /// (Craft / Notion highlight). Mutates the in-memory `EditableBlock`
    /// so the soft tinted band repaints immediately, then persists via
    /// the FFI. Registers the inverse on the UndoManager.
    func setBlockBackgroundColor(id: String, color: String?) {
        guard let idx = blocks.firstIndex(where: { $0.id == id }) else { return }
        let previous = blocks[idx].backgroundColor
        guard previous != color else { return }
        blocks[idx].backgroundColor = color
        do {
            try api.setBlockBackgroundColor(leafId: leafId, blockId: id, backgroundColor: color)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        undoMgr.registerUndo(withTarget: self) { vm in
            vm.setBlockBackgroundColor(id: id, color: previous)
        }
    }

    /// Applies (or clears with `nil`) the block-level text colour. Mutates
    /// the in-memory `EditableBlock` so the re-render picks up the new
    /// default foreground immediately, then persists via the FFI. Registers
    /// the inverse on the UndoManager so cmd-Z restores the previous colour.
    func setBlockColor(id: String, color: String?) {
        guard let idx = blocks.firstIndex(where: { $0.id == id }) else { return }
        let previous = blocks[idx].color
        guard previous != color else { return }
        blocks[idx].color = color
        do {
            try api.setBlockColor(leafId: leafId, blockId: id, color: color)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        undoMgr.registerUndo(withTarget: self) { vm in
            vm.setBlockColor(id: id, color: previous)
        }
    }

    /// Duplicates a block (with its descendants, all freshly UUID'd)
    /// and inserts the clone right after the original at the same
    /// tree level. Reloads via DFS-flatten so the visible list
    /// mirrors the Rust tree, then focuses the new block so the user
    /// sees where the copy landed. The undo inverse is a plain delete
    /// — the clone has a known UUID, no need to compare snapshots.
    func duplicateBlock(id: String) {
        flushAllBursts()
        do {
            let newId = try api.duplicateBlock(leafId: leafId, blockId: id)
            reloadBlocksAfterStructuralChange()
            autoFocusId = newId
            undoMgr.registerUndo(withTarget: self) { vm in
                vm.deleteBlock(id: newId)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Reloads the full leaf from SQLite after a structural mutation
    /// (indent / outdent). Index-based bookkeeping is no longer enough once
    /// the tree changes shape — we use the same DFS-flatten as `load()` so
    /// the visible block list mirrors the Rust tree, with `depth` driving
    /// the visual indentation in the row view.
    private func reloadBlocksAfterStructuralChange() {
        guard let doc = try? api.getLeaf(id: leafId) else { return }
        blocks = LeafViewModel.flattenBlocks(doc.blocks, depth: 0)
    }
}
