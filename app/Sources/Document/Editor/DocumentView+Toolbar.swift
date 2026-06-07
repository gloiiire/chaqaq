import SwiftUI

// ── Toolbar and overlay buttons ───────────────────────────────────────────────

extension DocumentView {

    @ToolbarContentBuilder
    var documentToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            // Tap = Safari-style "dezoom" sheet of recently opened
            // documents — primary affordance, what a user expects
            // when tapping a title bar.
            // Long-press = `.contextMenu` with the per-doc actions
            // (Rename / Lock / Share / Delete). We pick this trigger
            // over a pull-down `Menu` because SwiftUI's `Menu` lands
            // on UIKit's `UIMenu`, which renders items in
            // `.secondaryLabel` (dim grey) until highlighted —
            // `.foregroundStyle` overrides don't bite. `.contextMenu`
            // renders items at full `.label` brightness by default,
            // matching the long-press menu on a row in Apple Notes.
            Button {
                // Placeholder — keeps the bubble visually tappable
                // with the standard press animation while the
                // long-press / switcher feature isn't wired up.
            } label: {
                // Split the ternary so the empty-title branch keeps a
                // literal `Text("Untitled")` — SwiftUI auto-localizes
                // it via `Localizable.xcstrings`. A `Text(String)`
                // ternary would resolve to `String` and render
                // verbatim. See [[localizedstringkey-trap]].
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
                    // Matches the ~36-pt diameter of the iOS 26
                    // toolbar icon buttons next to it (lock, edit)
                    // so the bubble doesn't read smaller than its
                    // neighbours.
                    .frame(minHeight: 36)
            }
            .buttonStyle(.plain)
            .contentShape(Capsule(style: .continuous))
            .glassEffect(.regular.interactive(), in: Capsule(style: .continuous))
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
