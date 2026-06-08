import SwiftUI

/// iOS 26 morphing FAB inspired by Preview.app on iPad : compact
/// circular pencil button that fluidly stretches into a Liquid Glass
/// capsule of quick block icons when tapped. Re-tap on the leading
/// pencil icon (or one of the inner icons) collapses it back.
///
/// Uses `glassEffectID(_:in:)` so SwiftUI animates the glass shape
/// between Circle and Capsule with the system's Liquid Glass motion,
/// rather than a crossfade. The `GlassEffectContainer` is what wires
/// the morph — bare `.glassEffect(...)` modifiers don't share state.
struct ExpandingBlockFAB: View {
    @Binding var isExpanded: Bool
    /// Called when the user taps one of the quick block icons. The
    /// FAB collapses itself right after.
    let onSelect: (NewBlockType) -> Void
    /// Called when the user taps the overflow icon — opens the full
    /// `BlockPickerSheet`.
    let onOpenFullPicker: () -> Void

    @Namespace private var morphNs

    /// Every insertable block type — surfaced inline in the
    /// horizontally-scrollable capsule. No overflow / "more" button
    /// anymore; the user scrolls sideways to reach the long tail.
    private var allTypes: [NewBlockType] { NewBlockType.allCases }

    private let glassID = "block-fab-glass"

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            if isExpanded {
                expandedCapsule
            } else {
                compactCircle
            }
        }
    }

    private var compactCircle: some View {
        Button {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
                isExpanded = true
            }
        } label: {
            // Larger frame + explicit Circle contentShape so the
            // whole glass disc absorbs taps — `.glassEffect` alone
            // doesn't extend the hit area to its visible padding.
            Image(systemName: "pencil.and.outline")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 56, height: 56)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .tint(.primary)
        .glassEffect(.regular.interactive(), in: Circle())
        .glassEffectID(glassID, in: morphNs)
        // Drag-to-expand mirrors the swipe-to-collapse on the
        // capsule side — any meaningful swipe on the compact disc
        // morphs it open without requiring a precise tap.
        .simultaneousGesture(
            DragGesture(minimumDistance: 12)
                .onEnded { value in
                    let magnitude = hypot(value.translation.width,
                                          value.translation.height)
                    if magnitude > 20 {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
                            isExpanded = true
                        }
                    }
                }
        )
        .accessibilityLabel("Add block")
    }

    private var expandedCapsule: some View {
        // No leading collapse button — vertical swipe on the capsule
        // already snaps it back to its compact form, so the whole
        // capsule is dedicated to the horizontally-scrollable icon
        // strip.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(allTypes) { type in
                    Button {
                        onSelect(type)
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
                            isExpanded = false
                        }
                    } label: {
                        Image(systemName: type.icone)
                            .font(.system(size: 22, weight: .medium))
                            .frame(width: 48, height: 48)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .tint(.primary)
                    .accessibilityLabel(Text(type.displayName))
                }
            }
            .padding(.horizontal, 4)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        // Cap the capsule width so the scroll has something to work
        // against — without this it would stretch to whatever space
        // the parent gives it and there'd be no need to scroll.
        .frame(maxWidth: 340, alignment: .trailing)
        .glassEffect(.regular.interactive(), in: Capsule(style: .continuous))
        .glassEffectID(glassID, in: morphNs)
        // Clip the inner scrolling icons to the capsule shape so a
        // half-scrolled icon doesn't bleed past the glass border.
        .clipShape(Capsule(style: .continuous))
        .contentShape(Capsule(style: .continuous))
        // Vertical-only swipe-to-collapse — horizontal swipes are
        // reserved for scrolling the icon strip. We require the
        // vertical component to dominate by 1.5× to avoid stealing
        // ambiguous diagonal scrolls.
        .simultaneousGesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    let dy = abs(value.translation.height)
                    let dx = abs(value.translation.width)
                    if dy > 30 && dy > dx * 1.5 {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
                            isExpanded = false
                        }
                    }
                }
        )
    }
}
