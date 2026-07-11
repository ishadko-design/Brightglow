import SwiftUI

struct RootNavigator: View {
    @StateObject private var auth = AuthService()

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
    }
}
