import SwiftUI
import UIKit
import Supabase
import GoogleSignIn

@main
struct BrightglowApp: App {
    @StateObject private var chatRouter = ChatRouter()

    init() {
        registerFonts()
    }

    var body: some Scene {
        WindowGroup {
            RootNavigator()
                .environmentObject(chatRouter)
                .onOpenURL { url in
                    // A chat deep link (brightglow://chat) opens the inbox; only
                    // if it wasn't one do we treat the url as an auth callback.
                    if chatRouter.handle(url) { return }
                    GIDSignIn.sharedInstance.handle(url)
                    Task {
                        try? await supabase.auth.session(from: url)
                    }
                }
                // Universal Links (https://brightglow.co/chat…) arrive as a web
                // browsing activity rather than an openURL — route them to chat too.
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL { _ = chatRouter.handle(url) }
                }
        }
    }

    private func registerFonts() {
        let fonts = [
            "Lato-Regular", "Lato-Bold", "Lato-ExtraBold",
            "Poppins-Light", "Poppins-Regular"
        ]
        for name in fonts {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else {
                print("⚠️ Failed to load font: \(name)")
                continue
            }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
