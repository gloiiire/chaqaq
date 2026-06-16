import SwiftUI
import PinkhaCore

/// Collapsible group header rendered above each group in a List /
/// Gallery view : disclosure chevron, group title, entry count, and a
/// quick-add "+" that inserts a new entry already typed to the group's
/// value. Matches the Notion "▼ 2023 (11) +" affordance.
public struct BookGroupHeader: View {
    let title: String
    let count: Int
    let collapsed: Bool
    let onToggle: () -> Void
    let onAdd: () -> Void

    public var body: some View {
        HStack(spacing: 8) {
            Button {
                Haptic.tap()
                onToggle()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                    .animation(.easeOut(duration: 0.18), value: collapsed)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(title.isEmpty ? "Untitled" : title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Text("\(count)")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .monospacedDigit()

            Spacer(minLength: 0)

            Button {
                Haptic.tap()
                onAdd()
            } label: {
                Image(systemName: "plus")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }
}
