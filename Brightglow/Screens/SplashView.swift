import SwiftUI

/// First-launch loading screen shown while the session is being restored
/// (RootNavigator's `isRestoringSession` branch). Matches the Figma "Splash":
/// the warm-gradient backdrop (same asset the login screen uses) with the
/// centered Brightglow wordmark.
struct SplashView: View {
    var body: some View {
        ZStack {
            AppColors.bg.ignoresSafeArea()

            // The splash image already includes the left-aligned Brightglow
            // wordmark, so no separate Text overlay is needed.
            Image("SplashOverlay")
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .preferredColorScheme(.dark)
    }
}
