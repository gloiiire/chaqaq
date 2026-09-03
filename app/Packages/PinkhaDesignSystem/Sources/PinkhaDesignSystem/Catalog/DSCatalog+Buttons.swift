import SwiftUI

struct DSCatalogButtonsSection: View {
    @State private var pressCount = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                sample(".buttonStyle(.pinkha)") {
                    Button("Save") { pressCount += 1 }
                        .buttonStyle(.pinkha)
                }
                sample(".buttonStyle(.pinkha) + .tint(.pink)") {
                    Button("Continue") { pressCount += 1 }
                        .buttonStyle(.pinkha)
                        .tint(.pink)
                }
                sample("role: .destructive") {
                    Button(role: .destructive) { pressCount += 1 } label: {
                        Text("Delete leaf")
                    }
                    .buttonStyle(.pinkha)
                }
                sample("disabled") {
                    Button("Unavailable") { }
                        .buttonStyle(.pinkha)
                        .disabled(true)
                }
                sample(".buttonStyle(.pinkhaSoftPress)", description: "Micro-feedback wrapper for any label") {
                    Button {
                        pressCount += 1
                    } label: {
                        Image(systemName: "hand.tap.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .padding(14)
                            .background(.regularMaterial, in: Circle())
                    }
                    .buttonStyle(.pinkhaSoftPress)
                }
                Text("Presses: \(pressCount)")
                    .font(.pinkhaFootnote)
                    .foregroundStyle(Color.pinkhaLabelTertiary)
            }
            .padding()
        }
        .navigationTitle("Buttons")
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
