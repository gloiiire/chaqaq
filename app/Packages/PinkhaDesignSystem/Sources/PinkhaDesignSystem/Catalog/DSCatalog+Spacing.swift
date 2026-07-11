import SwiftUI

struct DSCatalogSpacingSection: View {
    var spacing = PinkhaSpacing()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                group("Spacing (Dynamic Type-scaled)") {
                    row("xs", value: spacing.xs)
                    row("s", value: spacing.s)
                    row("m", value: spacing.m)
                    row("l", value: spacing.l)
                    row("xl", value: spacing.xl)
                    row("xxl", value: spacing.xxl)
                }
                group("Radius") {
                    radiusRow("xs (6)", radius: PinkhaRadius.xs)
                    radiusRow("s (10)", radius: PinkhaRadius.s)
                    radiusRow("m (14)", radius: PinkhaRadius.m)
                    radiusRow("l (20)", radius: PinkhaRadius.l)
                    radiusRow("xl (28)", radius: PinkhaRadius.xl)
                }
                group("Concentricity") {
                    concentricDemo()
                }
            }
            .padding()
        }
        .navigationTitle("Spacing & Radius")
    }

    @ViewBuilder
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.pinkhaHeadline).foregroundStyle(Color.pinkhaLabelSecondary)
            VStack(alignment: .leading, spacing: 10) { content() }
        }
    }

    private func row(_ name: String, value: CGFloat) -> some View {
        HStack(spacing: 16) {
            Text(name).font(.pinkhaCodeInline).frame(width: 44, alignment: .leading)
            Rectangle().fill(Color.accentColor).frame(width: value, height: 20)
            Text("\(Int(value)) pt").font(.pinkhaCaption).foregroundStyle(Color.pinkhaLabelTertiary)
        }
    }

    private func radiusRow(_ name: String, radius: CGFloat) -> some View {
        HStack(spacing: 16) {
            Text(name).font(.pinkhaCodeInline).frame(width: 80, alignment: .leading)
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.accentColor.opacity(0.2))
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .stroke(Color.accentColor, lineWidth: 1)
                )
                .frame(width: 100, height: 60)
            Spacer()
        }
    }

    private func concentricDemo() -> some View {
        let parent: CGFloat = PinkhaRadius.xl
        let padding: CGFloat = 12
        let child = PinkhaRadius.concentric(parent: parent, padding: padding)
        return VStack(alignment: .leading, spacing: 8) {
            Text("parent=\(Int(parent)), padding=\(Int(padding)) → child=\(Int(child))")
                .font(.pinkhaCodeInline)
                .foregroundStyle(Color.pinkhaLabelTertiary)
            RoundedRectangle(cornerRadius: parent, style: .continuous)
                .fill(Color.accentColor.opacity(0.15))
                .frame(width: 220, height: 140)
                .overlay(
                    RoundedRectangle(cornerRadius: child, style: .continuous)
                        .fill(Color.accentColor.opacity(0.35))
                        .padding(padding)
                )
        }
    }
}
