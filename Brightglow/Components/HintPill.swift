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
            .background {
                ZStack {
                    Color.clear.background(.ultraThinMaterial)
                    Color(red: 0x13/255, green: 0x13/255, blue: 0x15/255).opacity(0.5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
    }
}
