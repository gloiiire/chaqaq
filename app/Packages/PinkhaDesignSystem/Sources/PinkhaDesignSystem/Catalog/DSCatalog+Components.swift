import SwiftUI

// Components section — showcases the 5 legacy DS components refactored on
// tokens in PRO-72. Each row demonstrates a representative call site so
// designers/devs can visually verify the token wiring in Xcode canvas.

struct DSCatalogComponentsSection: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                sample("SectionHeader") {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionHeader(title: "Recent")
                        SectionHeader(title: "Shelves")
                        SectionHeader(title: "Pinned")
                    }
                }

                sample("CoverImageView — placeholder (no cover set)") {
                    CoverImageView(cover: nil)
                        .frame(height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: PinkhaRadius.l, style: .continuous))
                }

                sample("CoverImageView — brand gradient preset") {
                    CoverImageView(cover: "cover.aurora")
                        .frame(height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: PinkhaRadius.l, style: .continuous))
                }

                sample("LockToolbarButton", description: "Tap to trigger the padlock keyframe animation") {
                    HStack(spacing: 24) {
                        LockToolbarButton(locked: false, accent: .accentColor) {}
                        LockToolbarButton(locked: true, accent: .accentColor) {}
                    }
                }

                sample("SystemAlertCard", description: "Pixel clone of iOS 26 UIAlertController") {
                    SystemAlertCard(
                        title: "Delete this leaf?",
                        message: "It will be moved to Compost — restorable.",
                        actions: [
                            .cancel(),
                            .destructive("Delete") {}
                        ]
                    )
                }
            }
            .padding()
        }
        .navigationTitle("Components")
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
