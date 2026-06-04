import SwiftUI

// ── Toolbar and overlay buttons ───────────────────────────────────────────────

extension DocumentView {

    @ToolbarContentBuilder
    var documentToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Text(vm.title.isEmpty ? "Untitled" : vm.title)
                .font(.headline)
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

    @ViewBuilder
    var overlayButtons: some View {
        if !vm.locked && editMode == .inactive && !keyboardVisible {
            FloatingButton(icon: "pencil.and.outline") { showingBlockPicker = true }
                .padding(.trailing, 24)
                .padding(.bottom, 32)
                .transition(.scale.combined(with: .opacity))
        }
        if !vm.locked && editMode == .inactive && !keyboardVisible {
            UndoRedoPill(canUndo: vm.canUndo, canRedo: vm.canRedo,
                         onUndo: { vm.undo() }, onRedo: { vm.redo() })
                .padding(.leading, 24)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.scale.combined(with: .opacity))
        }
    }
}
