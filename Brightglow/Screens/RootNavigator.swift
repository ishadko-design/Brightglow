import SwiftUI

struct RootNavigator: View {
    @StateObject private var auth = AuthService()
    @EnvironmentObject private var businessStore: BusinessStore

    var body: some View {
        Group {
            if auth.isRestoringSession {
                SplashView()
            } else if auth.isSignedIn {
                MainScreen()
            } else {
                LoginView()
            }
        }
        .environmentObject(auth)
        .animation(.easeInOut(duration: 0.25), value: auth.isSignedIn)
        .animation(.easeInOut(duration: 0.25), value: auth.isRestoringSession)
        // Resolve business ownership on sign-in (drives the "For business" entry
        // and deep-link routing); clear it on sign-out so accounts don't bleed.
        .task(id: auth.isSignedIn) {
            if auth.isSignedIn { await businessStore.load() }
            else { businessStore.reset() }
        }
    }
}
