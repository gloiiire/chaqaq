import SwiftUI

// Colors section — renders every semantic token twice (light + dark) via
// a side-by-side `.environment(\.colorScheme, .light/.dark)` split so the
// dynamic provider's variants are inspectable at a glance.

struct DSCatalogColorsSection: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                group("Foreground") {
                    swatch("pinkhaLabel", .pinkhaLabel)
                    swatch("pinkhaLabelSecondary", .pinkhaLabelSecondary)
                    swatch("pinkhaLabelTertiary", .pinkhaLabelTertiary)
                    swatch("pinkhaLabelQuaternary", .pinkhaLabelQuaternary)
                }
                group("Surface (base)") {
                    swatch("pinkhaSurface", .pinkhaSurface)
                    swatch("pinkhaSurfaceElevated", .pinkhaSurfaceElevated)
                    swatch("pinkhaSurfaceNested", .pinkhaSurfaceNested)
                }
                group("Surface (grouped)") {
                    swatch("pinkhaGrouped", .pinkhaGrouped)
                    swatch("pinkhaGroupedElevated", .pinkhaGroupedElevated)
                    swatch("pinkhaGroupedNested", .pinkhaGroupedNested)
                }
                group("Fill") {
                    swatch("pinkhaFill", .pinkhaFill)
                    swatch("pinkhaFillSecondary", .pinkhaFillSecondary)
                    swatch("pinkhaFillTertiary", .pinkhaFillTertiary)
                    swatch("pinkhaFillQuaternary", .pinkhaFillQuaternary)
                }
                group("Separator") {
                    swatch("pinkhaSeparator", .pinkhaSeparator)
                    swatch("pinkhaSeparatorOpaque", .pinkhaSeparatorOpaque)
                }
            }
            .padding()
        }
        .navigationTitle("Colors")
    }

    @ViewBuilder
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.pinkhaHeadline)
            VStack(spacing: 4) { content() }
        }
    }

    private func swatch(_ name: String, _ color: Color) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6).fill(color)
                .frame(width: 44, height: 28)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.pinkhaSeparator, lineWidth: 0.5)
                )
            Text(name).font(.pinkhaCodeInline)
            Spacer()
        }
    }
}
