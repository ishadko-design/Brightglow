import SwiftUI
import UIKit
import Supabase
import GoogleSignIn

@main
struct BrightglowApp: App {
    @StateObject private var chatRouter = ChatRouter()
    @StateObject private var businessStore = BusinessStore()

    init() {
        registerFonts()
    }

    var body: some Scene {
        WindowGroup {
            RootNavigator()
                .environmentObject(chatRouter)
                .environmentObject(businessStore)
                .onOpenURL { url in
                    #if DEBUG
                    print("🔗 onOpenURL: \(url.absoluteString)")
                    #endif
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
                    #if DEBUG
                    print("🔗 onContinueUserActivity(web): \(activity.webpageURL?.absoluteString ?? "nil")")
                    #endif
                    if let url = activity.webpageURL { _ = chatRouter.handle(url) }
                }
        }
    }

    private func registerFonts() {
        // Filenames, not PostScript names. `Lato-Heavy.ttf` is Lato's ExtraBold
        // (800) weight — Lato's own name for 800 is "Heavy", so DesignTokens
        // references it as `Lato-Heavy` (its internal PostScript name). It comes
        // from the full Lato 2 OFL family, not the Google Fonts subset.
        let fonts = [
            "Lato-Regular", "Lato-Bold", "Lato-Heavy",
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
