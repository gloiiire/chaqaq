import SwiftUI

// ── Building callbacks and block rows ────────────────────────────────────────

/// Installs the selection-mode tap-to-toggle recogniser when active.
/// Off, the modifier is a no-op so taps fall through to inner Buttons
/// (notably the navigation Button in `ChildPageRowView`).
private struct SelectionTapModifier: ViewModifier {
    let active: Bool
    let onTap: () -> Void

    func body(content: Content) -> some View {
        if active {
            content
                .contentShape(Rectangle())
                .onTapGesture(perform: onTap)
        } else {
            content
        }
    }
}

extension DocumentView {

    /// Builds the full row for a block in the List: selection HStack + content + gestures.
    @ViewBuilder
    func blockListRow(_ block: Binding<EditableBlock>) -> some View {
        let b = block.wrappedValue
        HStack(alignment: .center, spacing: 10) {
            if editMode == .active { selectionButton(b.id) }
            // Visual indentation for nested blocks. The Rust domain models
            // nesting as `Block.children`; we flatten the tree at load time
            // and translate the resulting `depth` to a leading padding here.
            // Each level shifts the block right by 20 pt — enough to read at
            // a glance, conservative to fit nested-3 on a narrow phone.
            if b.depth > 0 {
                Spacer().frame(width: CGFloat(b.depth) * 20)
            }
            BlockRowView(
                block: block,
                autoFocusId: $vm.autoFocusId,
                autoFocusOffset: $vm.autoFocusOffset,
                cb: blockCallbacks(for: b)
            )
            // Lock disables editing, NOT navigation. Page-reference
            // blocks are pure navigation targets (tap = push child doc)
            // so we keep them tappable even on a locked / selection-mode
            // parent — otherwise an imported, locked Notion page would
            // trap the user with no way to drill into its sub-pages.
            .disabled((vm.locked || editMode == .active) && !b.content.isPageReference)
            .allowsHitTesting((!vm.locked && editMode != .active) || b.content.isPageReference)
        }
        // contentShape + onTapGesture used to be unconditional, which
        // installed an HStack-level tap recogniser that swallowed taps
        // before they could reach inner controls (notably the Button
        // inside ChildPageRowView, killing navigation on locked docs).
        // We now only install the tap-to-toggle handler in selection
        // mode, where the behaviour is actually wanted.
        .modifier(SelectionTapModifier(active: editMode == .active,
                                       onTap: {
            withAnimation(.easeInOut(duration: 0.15)) { toggleSelection(b.id) }
        }))
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.35).onEnded { _ in selectFromLongPress(b.id) }
        )
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
        .swipeActions(edge: .trailing) {
            if !vm.locked && editMode != .active {
                Button(role: .destructive) { vm.deleteBlock(id: b.id) } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    /// Builds the `BlockCallbacks` bundle for a given block.
    /// Centralises block event routing logic to the VM.
    func blockCallbacks(for block: EditableBlock) -> BlockCallbacks {
        BlockCallbacks(
            onSave: {
                guard let idx = vm.blocks.firstIndex(where: { $0.id == block.id }) else { return }
                vm.saveBlock(vm.blocks[idx])
            },
            onSaveSpans: { spans in vm.saveBlock(id: block.id, spans: spans) },
            onDelete: {
                if let idx = vm.blocks.firstIndex(where: { $0.id == block.id }) {
                    if idx > 0 {
                        let prevId = vm.blocks[idx - 1].id
                        vm.deleteBlock(id: block.id)
                        vm.autoFocusId = prevId
                    } else {
                        vm.deleteBlock(id: block.id)
                        focusTitle = true
                    }
                }
            },
            onNewBlock: { afterSpans in
                vm.addBlock(type: .text, initialSpans: afterSpans, afterId: block.id)
            },
            onMerge: vm.blocks.first?.id == block.id ? { spansToMerge in
                // First block: merge its content into the title.
                let tail = spansToMerge.map(\.content).joined()
                let mergeOffset = vm.title.count
                vm.title += tail
                vm.saveTitle()
                vm.deleteBlock(id: block.id)
                titleFocusOffset = mergeOffset
                focusTitle = true
            } : { spansToMerge in
                guard let idx = vm.blocks.firstIndex(where: { $0.id == block.id }), idx > 0 else { return }
                let prevIdx = idx - 1
                let prevId = vm.blocks[prevIdx].id
                let mergeOffset = vm.blocks[prevIdx].spans.map(\.content).joined().count
                vm.blocks[prevIdx].spans += spansToMerge
                vm.saveBlock(vm.blocks[prevIdx])
                vm.deleteBlock(id: block.id)
                vm.autoFocusOffset = mergeOffset
                vm.autoFocusId = prevId
            },
            onNavigatePrevious: {
                guard !vm.isNavigating else { return }
                guard let idx = vm.blocks.firstIndex(where: { $0.id == block.id }) else { return }
                if idx > 0 {
                    let nid = vm.blocks[idx - 1].id
                    vm.autoFocusOffset = nil; vm.autoFocusId = nid
                    vm.startNavigationRepeat(from: nid, next: false)
                } else { focusTitle = true }
            },
            onNavigateNext: {
                guard !vm.isNavigating else { return }
                guard let idx = vm.blocks.firstIndex(where: { $0.id == block.id }),
                      idx < vm.blocks.count - 1 else { return }
                let nid = vm.blocks[idx + 1].id
                vm.autoFocusOffset = 0; vm.autoFocusId = nid
                vm.startNavigationRepeat(from: nid, next: true)
            },
            onStopNavigationRepeat: { vm.stopNavigationRepeat() },
            onLongPressSelection: { selectFromLongPress(block.id) },
            onFocus: { vm.activeBlockId = block.id },
            onToggleDone: { vm.toggleBlockDone(id: block.id) },
            onChangeIcon: { icon in vm.updateBlockIcon(id: block.id, icon: icon) },
            onConvertContent: { content in vm.convertBlockContent(id: block.id, to: content) },
            onUndo: { vm.undo() },
            onRedo: { vm.redo() },
            canUndoProvider: { vm.canUndo },
            canRedoProvider: { vm.canRedo },
            onIndent: { vm.indentBlock(id: block.id) },
            onOutdent: { vm.outdentBlock(id: block.id) },
            onSetBlockColor: { color in vm.setBlockColor(id: block.id, color: color) },
            onOpenInternalDoc: { docId in pushedDocId = docId },
            resolveChildPage: { childId in
                // The child-page row needs a title + optional icon. We load
                // the document JSON synchronously off the SQLite store —
                // cheap on local disk, and the call is gated by `.onAppear`
                // in `ChildPageRowView` so we hit the store at most once
                // per child block surfaced.
                guard let json = try? vm.api.getDocumentJson(id: childId),
                      let data = json.data(using: .utf8),
                      let doc = try? JSONDecoder().decode(DocumentFfi.self, from: data)
                else { return nil }
                let title = doc.title.map(\.content).joined()
                return (title: title, icon: doc.icon)
            }
        )
    }
}
