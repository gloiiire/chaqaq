import SwiftUI

struct DSCatalogIconCapsuleSection: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                sample("Default (tint = .primary)") {
                    IconCapsuleButton(
                        systemImage: "xmark",
                        accessibilityLabel: "Close"
                    ) {}
                }
                sample("Custom tint") {
                    IconCapsuleButton(
                        systemImage: "sparkles",
                        accessibilityLabel: "Enchant",
                        tint: .accentColor
                    ) {}
                }
                sample("role: .destructive") {
                    IconCapsuleButton(
                        systemImage: "trash",
                        accessibilityLabel: "Delete",
                        role: .destructive
                    ) {}
                }
                sample("Over a colourful background", description: "Vibrancy check on Liquid Glass") {
                    IconCapsuleButton(
                        systemImage: "chevron.left",
                        accessibilityLabel: "Back"
                    ) {}
                        .padding(30)
                        .frame(maxWidth: .infinity)
                        .background(
                            LinearGradient(
                                colors: [.orange, .pink, .purple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: PinkhaRadius.l))
                }
            }
            .padding()
        }
        .navigationTitle("Icon capsule")
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
