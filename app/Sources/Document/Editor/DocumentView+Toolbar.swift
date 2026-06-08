import SwiftUI

// ── Toolbar and overlay buttons ───────────────────────────────────────────────

extension DocumentView {

    @ToolbarContentBuilder
    var documentToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            // The principal slot fades in once the user scrolls past
            // the inline title (~60 pt). Shows the current doc title
            // alone for root pages, OR a Notion-style breadcrumb
            // (Parent › Child › This) for nested sub-pages — tap on
            // any segment dismisses back to that ancestor.
            titleBubble
                .opacity(titleInNavBar ? 1 : 0)
                .offset(y: titleInNavBar ? 0 : 8)
                .animation(.easeOut(duration: 0.2), value: titleInNavBar)
        }
        if editMode == .active && !selectedBlocks.isEmpty && !vm.locked {
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) { deleteSelectedBlocks() } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Delete selected blocks")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                let newLocked = !vm.locked
                withAnimation(.easeInOut(duration: 0.15)) {
                    // Apply UI side-effects of locking *before* the save
                    // round-trip — they only depend on `newLocked` and would
                    // race the @Published change otherwise.
                    if newLocked {
                        editMode = .inactive; selectedBlocks.removeAll()
                        focusTitle = false; showingBlockPicker = false
                        vm.stopNavigationRepeat()
                    }
                    // VM is the source of truth for the lock flag now —
                    // persists to SQLite via the FFI + registers undo.
                    vm.saveLocked(newLocked)
                }
            } label: {
                Image(systemName: vm.locked ? "lock.fill" : "lock.open.fill")
            }
            // Only the locked state earns the accent — the unlocked
            // open-lock keeps the neutral material color so the rest
            // of the toolbar reads as quiet chrome.
            .tint(vm.locked ? settings.accentColor : .primary)
            .accessibilityLabel(vm.locked ? "Unlock document" : "Lock document")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                withAnimation {
                    editMode = editMode == .active ? .inactive : .active
                    if editMode != .active { selectedBlocks.removeAll() }
                }
            } label: {
                Image(systemName: editMode == .active ? "checkmark" : "arrow.up.arrow.down")
            }
            // Neutral chrome — override the TabView's accent that
            // propagates through the env.
            .tint(.primary)
            .disabled(vm.locked)
        }
    }

    /// Whether `vm.docId` is somewhere below `targetId` in the
    /// `parentDocId` tree (used by the popToDoc handler to defensively
    /// clear pushedDocId on every doc between the target and current).
    /// No depth cap — `seen` is the cycle guard, so legitimate trees
    /// can nest arbitrarily deep. Walk stops only on a cycle or root.
    func isDescendant(of targetId: String) -> Bool {
        var currentId = vm.docId
        var seen: Set<String> = [currentId]
        while let meta = docMetaById[currentId],
              let parentId = meta.parentDocId,
              !seen.contains(parentId) {
            if parentId == targetId { return true }
            seen.insert(parentId)
            currentId = parentId
        }
        return false
    }

    /// Walks up the `parentDocId` chain via `store.documents` to build
    /// the breadcrumb. Root → … → this doc. Returns `[self]` for root
    /// pages (single segment, rendered as a plain title bubble).
    private var breadcrumbPath: [DocumentMetaFfi] {
        // `docMetaById` is loaded on appear from `listDocuments()`
        // (includes sub-pages, unlike `store.documents` which is
        // root-only). Until it's populated, no breadcrumb is shown.
        guard var node = docMetaById[vm.docId] else { return [] }
        var path: [DocumentMetaFfi] = [node]
        var seen: Set<String> = [node.id]
        while let parentId = node.parentDocId,
              let parent = docMetaById[parentId],
              !seen.contains(parent.id) {
            path.insert(parent, at: 0)
            seen.insert(parent.id)
            node = parent
        }
        return path
    }

    @ViewBuilder
    private var titleBubble: some View {
        let path = breadcrumbPath
        if path.count > 1 {
            // Breadcrumb : tap any ancestor segment to dismiss back to
            // it. Truncates each segment so the bubble fits on screen
            // even with long titles.
            HStack(spacing: 4) {
                ForEach(Array(path.enumerated()), id: \.element.id) { idx, meta in
                    if idx > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    let isLast = idx == path.count - 1
                    let titleText = Text(meta.titlePlain.isEmpty
                                          ? "Untitled" : meta.titlePlain)
                        .font(.subheadline.weight(isLast ? .semibold : .regular))
                        .foregroundStyle(isLast ? .primary : .secondary)
                    if isLast {
                        // Current doc — non-tappable, just shows
                        // "you are here" in the chain.
                        titleText
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        // Ancestor — tap pops the NavStack to it.
                        Button {
                            NotificationCenter.default.post(
                                name: Composer.popToDocNotification,
                                object: nil,
                                userInfo: ["docId": meta.id])
                        } label: {
                            titleText
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 36)
            .glassEffect(.regular.interactive(), in: Capsule(style: .continuous))
        } else {
            // Root page : plain title bubble (no breadcrumb chevrons).
            Button {
                // Placeholder — keeps the bubble tappable until the
                // long-press / switcher feature is wired up.
            } label: {
                Group {
                    if vm.title.isEmpty {
                        Text("Untitled")
                    } else {
                        Text(vm.title)
                    }
                }
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .frame(minHeight: 36)
            }
            .buttonStyle(.plain)
            .contentShape(Capsule(style: .continuous))
            .glassEffect(.regular.interactive(), in: Capsule(style: .continuous))
        }
    }

    @ViewBuilder
    var overlayButtons: some View {
        if !vm.locked && editMode == .inactive && !keyboardVisible {
            ExpandingBlockFAB(
                isExpanded: $blockFABExpanded,
                onSelect: { type in vm.addBlock(type: type, afterId: vm.activeBlockId) },
                onOpenFullPicker: { showingBlockPicker = true }
            )
            .padding(.trailing, 24)
            .padding(.bottom, accessoryPlacement == .inline ? -70 : 8)
            .transition(.scale.combined(with: .opacity))
        }
        // UndoRedoPill steps aside while the right FAB is morphed
        // into its expanded capsule, so the two floating chunks
        // don't visually fight for space.
        if !vm.locked && editMode == .inactive && !keyboardVisible && !blockFABExpanded {
            UndoRedoPill(canUndo: vm.canUndo, canRedo: vm.canRedo,
                         onUndo: { vm.undo() }, onRedo: { vm.redo() })
                .padding(.leading, 24)
                .padding(.bottom, accessoryPlacement == .inline ? -70 : 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.scale.combined(with: .opacity))
        }
    }
}
