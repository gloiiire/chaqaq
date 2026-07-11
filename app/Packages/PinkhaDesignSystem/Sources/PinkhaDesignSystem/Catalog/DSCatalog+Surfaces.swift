import SwiftUI

struct DSCatalogSurfacesSection: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                sample("pinkhaCard()", description: "Regular material, medium radius") {
                    Text("Card body")
                        .font(.pinkhaBody)
                        .padding(20)
                        .frame(maxWidth: .infinity)
                        .pinkhaCard()
                }
                sample("pinkhaCard(radius: .l)") {
                    Text("Large radius card")
                        .font(.pinkhaBody)
                        .padding(20)
                        .frame(maxWidth: .infinity)
                        .pinkhaCard(radius: PinkhaRadius.l)
                }
                sample("pinkhaChrome()", description: "Toolbar bar material") {
                    Text("Chrome bar")
                        .font(.pinkhaHeadline)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .pinkhaChrome()
                }
                sample("pinkhaGlassCapsule(in: Circle())", description: "iOS 27 Liquid Glass fallback") {
                    Image(systemName: "sparkles")
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: 56, height: 56)
                        .pinkhaGlassCapsule(in: Circle())
                }
            }
            .padding()
        }
        .navigationTitle("Surfaces")
    }

    @ViewBuilder
    private func sample<Content: View>(
        _ code: String,
        description: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(code).font(.pinkhaCodeInline).foregroundStyle(Color.pinkhaLabelSecondary)
            if let description {
                Text(description).font(.pinkhaCaption).foregroundStyle(Color.pinkhaLabelTertiary)
            }
            content()
        }
    }
}
