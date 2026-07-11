import SwiftUI

struct DSCatalogAccentsSection: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Each accent is backed by a `UIColor.system*` value — dynamic across light/dark/HighContrast/Elevated without an Asset Catalog.")
                    .font(.pinkhaFootnote)
                    .foregroundStyle(Color.pinkhaLabelSecondary)

                VStack(spacing: 8) {
                    ForEach(PinkhaAccentPalette.all) { accent in
                        HStack(spacing: 12) {
                            Circle()
                                .fill(accent.color)
                                .frame(width: 32, height: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(accent.displayNameKey).font(.pinkhaBody)
                                Text(accent.name).font(.pinkhaCodeInline)
                                    .foregroundStyle(Color.pinkhaLabelTertiary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Accents")
    }
}
