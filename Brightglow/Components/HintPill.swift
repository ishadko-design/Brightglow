import SwiftUI

/// Frosted-glass hint label that auto-dismisses after a given duration.
struct HintPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.bodyLight)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background {
                ZStack {
                    Color.clear.background(.ultraThinMaterial)
                    Color(red: 0x13/255, green: 0x13/255, blue: 0x15/255).opacity(0.5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
            // Always keep the pill 16pt off the screen edges; the label wraps to
            // a second line rather than running to the edge.
            .padding(.horizontal, 16)
    }
}
