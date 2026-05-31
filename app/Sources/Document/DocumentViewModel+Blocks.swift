import SwiftUI

// ── Gestion des blocs ─────────────────────────────────────────────────────────

extension DocumentViewModel {

    func addBlock(type: NewBlockType, initialSpans: [InlineTextFfi] = [], afterId: String? = nil) {
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
                                         blockContentJson: String(data: data, encoding: .utf8)!)
            let newBlock = EditableBlock(id: newId, content: content, spans: initialSpans, done: false)

            if let afterId, let idx = blocks.firstIndex(where: { $0.id == afterId }) {
                blocks.insert(newBlock, at: idx + 1)
                try? api.reorderBlocks(docId: docId, order: blocks.map(\.id))
            } else {
                blocks.append(newBlock)
            }
            if !initialSpans.isEmpty { persistBlockRaw(newBlock) }
            blockSnapshots[newId] = snapshotOf(newBlock)
            autoFocusOffset = 0
            autoFocusId = newId
            // Undo : supprime le bloc qu'on vient de créer. deleteBlock auto-enregistre le redo (réinsertion).
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
            // Undo : réinsère le bloc à sa position d'origine. reinsertBlock enregistre le redo.
            undoMgr.registerUndo(withTarget: self) { vm in
                vm.reinsertBlock(block, at: index)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    /// Recrée un bloc supprimé via l'API (génère un nouvel UUID) puis le reordonne
    /// à sa position d'origine. L'UUID change à travers les cycles undo mais le contenu
    /// est préservé — comportement undo iOS standard.
    /// Focus automatique sur le bloc restauré (curseur en fin) — UX standard pour undo d'une suppression.
    private func reinsertBlock(_ block: EditableBlock, at index: Int) {
        do {
            let content = block.content.withSpans(block.spans, done: block.done)
            let data = try JSONEncoder().encode(content)
            let newId = try api.addBlock(docId: docId,
                                         blockContentJson: String(data: data, encoding: .utf8)!)
            let recreated = EditableBlock(id: newId, content: content,
                                          spans: block.spans, done: block.done)
            let safeIndex = min(index, blocks.count)
            blocks.insert(recreated, at: safeIndex)
            try api.reorderBlocks(docId: docId, order: blocks.map(\.id))
            blockSnapshots[newId] = snapshotOf(recreated)
            autoFocusOffset = nil
            autoFocusId = newId
            // Redo : re-supprime ce bloc.
            undoMgr.registerUndo(withTarget: self) { vm in vm.deleteBlock(id: newId) }
        } catch { errorMessage = error.localizedDescription }
    }

    func deleteBlocks(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        for id in ids { flushBurst(blockId: id) }
        // Capture les snapshots avec leurs indices (croissant) pour une restauration ordonnée.
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

    /// Bascule l'état "done" d'un bloc todo. Undo le rebascule (auto-re-enregistrement).
    func toggleBlockDone(id: String) {
        guard let idx = blocks.firstIndex(where: { $0.id == id }) else { return }
        blocks[idx].done.toggle()
        persistBlock(blocks[idx])
        undoMgr.registerUndo(withTarget: self) { vm in vm.toggleBlockDone(id: id) }
    }

    /// Met à jour l'icône emoji d'un bloc callout. Undo restaure l'icône précédente.
    func updateBlockIcon(id: String, icon: String) {
        guard let idx = blocks.firstIndex(where: { $0.id == id }) else { return }
        guard case .quote(let oldIcon, _) = blocks[idx].content, oldIcon != icon else { return }
        blocks[idx].content = .quote(icon: icon, text: blocks[idx].spans)
        persistBlock(blocks[idx])
        undoMgr.registerUndo(withTarget: self) { vm in
            vm.updateBlockIcon(id: id, icon: oldIcon)
        }
    }

    /// Convertit le contenu d'un bloc (raccourci markdown : text → heading, etc.).
    /// Undo restaure le contenu + spans précédents ; redo réapplique la conversion.
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

    /// Applique un ordre de blocs (utilisé par undo/redo de moveBlock).
    private func applyBlockOrder(_ order: [String]) {
        let oldOrder = blocks.map(\.id)
        let lookup = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
        blocks = order.compactMap { lookup[$0] }
        try? api.reorderBlocks(docId: docId, order: order)
        undoMgr.registerUndo(withTarget: self) { vm in vm.applyBlockOrder(oldOrder) }
    }
}
