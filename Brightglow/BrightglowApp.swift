import SwiftUI
import UIKit
import Supabase
import GoogleSignIn

@main
struct BrightglowApp: App {
    init() {
        registerFonts()
    }

    var body: some Scene {
        WindowGroup {
            RootNavigator()
                .onOpenURL { url in
                    GIDSignIn.sharedInstance.handle(url)
                    Task {
                        try? await supabase.auth.session(from: url)
                    }
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
