import SwiftUI

// ── Block management ──────────────────────────────────────────────────────────

extension DocumentViewModel {

    func addBlock(type: NewBlockType, initialSpans: [InlineTextFfi] = [], afterId: String? = nil, atStart: Bool = false) {
        do {
            let content: BlockContentFfi
            switch type {
            case .text:    content = .text([])
            case .title1:  content = .heading(level: 1, text: [])
            case .title2:  content = .heading(level: 2, text: [])
            case .title3:  content = .heading(level: 3, text: [])
            case .quote:   content = .quote(icon: "", text: [])
            case .callout: content = .quote(icon: "💡", text: [])
            case .todo:    content = .todo(done: false, text: [])
            case .divider: content = .divider
            }
            let data  = try JSONEncoder().encode(content)
            let newId = try api.addBlock(docId: docId,
                                         blockContentJson: String(decoding: data, as: UTF8.self))
            let newBlock = EditableBlock(id: newId, content: content, spans: initialSpans, done: false)

            if let afterId, let idx = blocks.firstIndex(where: { $0.id == afterId }) {
                blocks.insert(newBlock, at: idx + 1)
                try? api.reorderBlocks(docId: docId, order: blocks.map(\.id))
            } else if atStart {
                blocks.insert(newBlock, at: 0)
                try? api.reorderBlocks(docId: docId, order: blocks.map(\.id))
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

    func deleteBlock(id: String) {
        flushBurst(blockId: id)
        guard let block = blocks.first(where: { $0.id == id }),
              let index = blocks.firstIndex(where: { $0.id == id })
        else { return }
        do {
            try api.deleteBlock(docId: docId, blockId: id)
            blocks.removeAll { $0.id == id }
            blockSnapshots.removeValue(forKey: id)
            // Undo: reinsert the block at its original position. reinsertBlock registers the redo.
            undoMgr.registerUndo(withTarget: self) { vm in
                vm.reinsertBlock(block, at: index)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    /// Recreates a deleted block via the API (generates a new UUID) then reorders it
    /// to its original position. The UUID changes across undo cycles but the content
    /// is preserved — standard iOS undo behaviour.
    /// Auto-focus on the restored block (cursor at end) — standard UX for undo of a deletion.
    private func reinsertBlock(_ block: EditableBlock, at index: Int) {
        do {
            let content = block.content.withSpans(block.spans, done: block.done)
            let data = try JSONEncoder().encode(content)
            let newId = try api.addBlock(docId: docId,
                                         blockContentJson: String(decoding: data, as: UTF8.self))
            let recreated = EditableBlock(id: newId, content: content,
                                          spans: block.spans, done: block.done)
            let safeIndex = min(index, blocks.count)
            blocks.insert(recreated, at: safeIndex)
            try api.reorderBlocks(docId: docId, order: blocks.map(\.id))
            blockSnapshots[newId] = snapshotOf(recreated)
            autoFocusOffset = nil
            autoFocusId = newId
            // Redo: re-delete this block.
            undoMgr.registerUndo(withTarget: self) { vm in vm.deleteBlock(id: newId) }
        } catch { errorMessage = error.localizedDescription }
    }

    func deleteBlocks(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        for id in ids { flushBurst(blockId: id) }
        // Capture snapshots with their indices (ascending) for ordered restoration.
        let snapshots: [(Int, EditableBlock)] = blocks.enumerated()
            .filter { ids.contains($0.element.id) }
            .map { ($0.offset, $0.element) }
        do {
            for id in ids {
                try api.deleteBlock(docId: docId, blockId: id)
            }
            blocks.removeAll { ids.contains($0.id) }
            for id in ids { blockSnapshots.removeValue(forKey: id) }
            undoMgr.registerUndo(withTarget: self) { vm in
                vm.undoMgr.beginUndoGrouping()
                for (index, block) in snapshots {
                    vm.reinsertBlock(block, at: index)
                }
                vm.undoMgr.endUndoGrouping()
            }
        } catch { errorMessage = error.localizedDescription }
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
        blocks[idx].spans = []
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
        try? api.reorderBlocks(docId: docId, order: newOrder)
        undoMgr.registerUndo(withTarget: self) { vm in vm.applyBlockOrder(oldOrder) }
    }

    /// Applies a block order (used by undo/redo of moveBlock).
    private func applyBlockOrder(_ order: [String]) {
        let oldOrder = blocks.map(\.id)
        let lookup = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
        blocks = order.compactMap { lookup[$0] }
        try? api.reorderBlocks(docId: docId, order: order)
        undoMgr.registerUndo(withTarget: self) { vm in vm.applyBlockOrder(oldOrder) }
    }

    /// Indents the given block — moves it under the previous sibling at the
    /// same level. The tree shape changes (not just the order), so we reload
    /// the full document from SQLite afterwards.
    ///
    /// `InvalidOperation` from the FFI (block is the first of its level —
    /// nothing to indent under) surfaces via `errorMessage` like any other
    /// error; the UI uses `.errorAlert` to show it.
    func indentBlock(id: String) {
        flushAllBursts()
        do {
            try api.indentBlock(docId: docId, blockId: id)
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
            try api.outdentBlock(docId: docId, blockId: id)
            reloadBlocksAfterStructuralChange()
        } catch {
            errorMessage = error.localizedDescription
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
            try api.setBlockColor(docId: docId, blockId: id, color: color)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        undoMgr.registerUndo(withTarget: self) { vm in
            vm.setBlockColor(id: id, color: previous)
        }
    }

    /// Reloads the full document from SQLite after a structural mutation
    /// (indent / outdent). Index-based bookkeeping is no longer enough once
    /// the tree changes shape — we use the same DFS-flatten as `load()` so
    /// the visible block list mirrors the Rust tree, with `depth` driving
    /// the visual indentation in the row view.
    private func reloadBlocksAfterStructuralChange() {
        guard let json = try? api.getDocumentJson(id: docId),
              let data = json.data(using: .utf8),
              let doc = try? JSONDecoder().decode(DocumentFfi.self, from: data) else {
            return
        }
        blocks = DocumentViewModel.flattenBlocks(doc.blocks, depth: 0)
    }
}
