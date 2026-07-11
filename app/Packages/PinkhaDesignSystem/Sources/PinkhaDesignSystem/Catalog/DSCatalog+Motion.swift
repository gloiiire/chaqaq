import SwiftUI

struct DSCatalogMotionSection: View {
    @State private var animateFast = false
    @State private var animateDefault = false
    @State private var animateEmphasized = false
    @State private var animateSmooth = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Tap a swatch to preview its animation.")
                    .font(.pinkhaCallout)
                    .foregroundStyle(Color.pinkhaLabelSecondary)

                motionRow("PinkhaMotion.fast", $animateFast, motion: PinkhaMotion.fast)
                motionRow("PinkhaMotion.default", $animateDefault, motion: PinkhaMotion.default)
                motionRow("PinkhaMotion.emphasized", $animateEmphasized, motion: PinkhaMotion.emphasized)
                motionRow("PinkhaMotion.smooth", $animateSmooth, motion: PinkhaMotion.smooth)
            }
            .padding()
        }
        .navigationTitle("Motion")
    }

    private func motionRow(_ name: String, _ trigger: Binding<Bool>, motion: Animation) -> some View {
        HStack(spacing: 16) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 32, height: 32)
                .offset(x: trigger.wrappedValue ? 160 : 0)
                .animation(motion, value: trigger.wrappedValue)
            Spacer()
            Button(name) {
                trigger.wrappedValue.toggle()
            }
            .buttonStyle(.plain)
            .font(.pinkhaCodeInline)
            .foregroundStyle(Color.accentColor)
        }
        .padding(.vertical, 8)
    }
}
