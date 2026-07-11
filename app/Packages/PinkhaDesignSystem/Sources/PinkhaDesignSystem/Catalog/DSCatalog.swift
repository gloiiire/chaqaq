import SwiftUI

// MARK: - DS catalog
//
// Living documentation of the design system. Open in Xcode preview canvas
// (the `#Preview` below renders directly) or drop into a debug menu at
// runtime for a full browsable inspector. Every token, primitive, and
// component has a section here — if you add one to the DS, add its row
// here in the same commit.

public struct DSCatalog: View {
    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink("Colors", destination: DSCatalogColorsSection())
                    NavigationLink("Typography", destination: DSCatalogTypographySection())
                    NavigationLink("Spacing & Radius", destination: DSCatalogSpacingSection())
                    NavigationLink("Motion", destination: DSCatalogMotionSection())
                } header: {
                    Text("Tokens")
                }

                Section {
                    NavigationLink("Surfaces", destination: DSCatalogSurfacesSection())
                    NavigationLink("Buttons", destination: DSCatalogButtonsSection())
                    NavigationLink("Icon capsule", destination: DSCatalogIconCapsuleSection())
                } header: {
                    Text("Primitives")
                }

                Section {
                    NavigationLink("Legacy components", destination: DSCatalogComponentsSection())
                } header: {
                    Text("Components")
                }

                Section {
                    NavigationLink("Accents", destination: DSCatalogAccentsSection())
                } header: {
                    Text("Brand")
                }
            }
            .navigationTitle("Pinkha DS")
        }
    }
}

#Preview("DS Catalog") {
    DSCatalog()
}
