import SwiftUI

struct DSCatalogTypographySection: View {
    private let sampleText = "The quick brown fox jumps over the lazy dog"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                group("Structural") {
                    sample("pinkhaLargeTitle", font: .pinkhaLargeTitle)
                    sample("pinkhaTitle", font: .pinkhaTitle)
                    sample("pinkhaTitle2", font: .pinkhaTitle2)
                    sample("pinkhaTitle3", font: .pinkhaTitle3)
                    sample("pinkhaHeadline", font: .pinkhaHeadline)
                    sample("pinkhaBody", font: .pinkhaBody)
                    sample("pinkhaCallout", font: .pinkhaCallout)
                    sample("pinkhaFootnote", font: .pinkhaFootnote)
                    sample("pinkhaCaption", font: .pinkhaCaption)
                }
                group("Reading") {
                    sample("pinkhaLeafH1", font: .pinkhaLeafH1)
                    sample("pinkhaLeafH2", font: .pinkhaLeafH2)
                    sample("pinkhaLeafH3", font: .pinkhaLeafH3)
                    sample("pinkhaLeafBody", font: .pinkhaLeafBody)
                }
                group("Code") {
                    sample("pinkhaCode", font: .pinkhaCode)
                    sample("pinkhaCodeInline", font: .pinkhaCodeInline)
                }
                group("Section header") {
                    Text("pinkhaSectionHeader".uppercased())
                        .font(.pinkhaSectionHeader)
                        .kerning(0.8)
                        .foregroundStyle(Color.pinkhaLabelSecondary)
                }
            }
            .padding()
        }
        .navigationTitle("Typography")
    }

    @ViewBuilder
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.pinkhaHeadline).foregroundStyle(Color.pinkhaLabelSecondary)
            VStack(alignment: .leading, spacing: 10) { content() }
        }
    }

    private func sample(_ name: String, font: Font) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(sampleText).font(font)
            Text(name).font(.pinkhaCodeInline).foregroundStyle(Color.pinkhaLabelTertiary)
        }
    }
}
