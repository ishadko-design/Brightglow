import SwiftUI

struct FixrButton: View {
    enum Style { case gradient, frosted, text }

    let label: String
    var style: Style = .gradient
    var loading: Bool = false
    let action: () -> Void

    var body: some View {
        if style == .frosted {
            coreButton.buttonStyle(.frosted)
        } else if style == .text {
            coreButton.buttonStyle(.textAction)
        } else {
            coreButton.buttonStyle(.gradient)
        }
    }

    private var coreButton: some View {
        Button(action: action) {
            Group {
                if loading {
                    ProgressView().tint(.white)
                } else {
                    Text(label)
                        .font(.h3)
                        .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 54)
        }
        .disabled(loading)
    }
}

#Preview {
    VStack(spacing: 16) {
        FixrButton(label: "Request Quote", style: .gradient) {}
        FixrButton(label: "Skip",          style: .frosted) {}
        FixrButton(label: "Use a different email", style: .text) {}
        FixrButton(label: "Loading…",      style: .gradient, loading: true) {}
    }
    .padding(24)
    .background(AppColors.bg)
}
