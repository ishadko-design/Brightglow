import SwiftUI

/// First-launch loading screen shown while the session is being restored
/// (RootNavigator's `isRestoringSession` branch): the solid splash PNG (a warm
/// gradient, no wordmark baked in) with the Brightglow wordmark drawn in code.
struct SplashView: View {
    var body: some View {
        ZStack {
            AppColors.bg.ignoresSafeArea()

            Image("SplashOverlay")
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()
                .allowsHitTesting(false)

            // Wordmark, centered in the vertical middle — rendered in code
            // (the solid PNG has no wordmark baked in).
            Text("Brightglow")
                .font(.h1)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 32)
                .allowsHitTesting(false)
        }
        .preferredColorScheme(.dark)
    }
}
