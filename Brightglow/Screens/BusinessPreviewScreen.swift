import SwiftUI
import Combine

/// Carries a `brightglow://preview/<place_id>` deep link into the UI. A business
/// tapping "Preview as customer" in the web portal (/biz) lands here; `MainScreen`
/// consumes `placeID` to present the consumer-facing gallery in `previewMode`, so
/// the owner sees exactly what a customer sees — no login required (a public
/// profile view).
@MainActor
final class PreviewRouter: ObservableObject {
    /// The place to preview, or nil when there's nothing pending.
    @Published var placeID: String? = nil

    /// Returns true if it consumed the url (a preview deep link), so the caller
    /// knows not to also hand it to the chat/auth handlers. Accepts both the
    /// custom scheme (brightglow://preview/<id>) and the https Universal Link
    /// (https://brightglow.co/preview/<id>), so the portal button works whether or
    /// not Universal Links are configured yet.
    func handle(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        let host = url.host?.lowercased()

        let isCustomScheme = scheme == "brightglow" && host == "preview"
        let isUniversalLink = scheme == "https"
            && (host == "brightglow.co" || host == "www.brightglow.co")
            && url.path.lowercased().hasPrefix("/preview")

        guard isCustomScheme || isUniversalLink else { return false }

        // Pull the place id out of the path:
        //   brightglow://preview/<id>          → host "preview", path "/<id>"
        //   https://brightglow.co/preview/<id> → path "/preview/<id>"
        let segments = url.pathComponents.filter { $0 != "/" }
        let id = isCustomScheme ? segments.first
                                : (segments.count >= 2 ? segments[1] : nil)

        guard let id, !id.isEmpty else { return true }   // consumed, but nothing to open
        placeID = id
        return true
    }
}

/// A one-place identifier wrapper so `MainScreen` can drive a `fullScreenCover`
/// off the pending preview place id.
struct PreviewTarget: Identifiable, Equatable {
    let id: String
}

/// Full-screen preview of how a customer sees a business, resolved from just a
/// place id (the deep-link entry point). Mirrors the in-app "View profile"
/// preview (`ProfilePreviewScreen`), but fetches the SAVED profile from the DB —
/// which is exactly what consumers read — instead of live editor state.
struct BusinessPreviewScreen: View {
    let placeId: String

    @Environment(\.dismiss) private var dismiss
    @State private var contractor: Contractor?
    @State private var profile: BusinessService.BusinessProfile?
    @State private var resolved = false

    var body: some View {
        ZStack {
            AppColors.bg.ignoresSafeArea()
            if let contractor {
                ContractorGalleryScreen(
                    // No search context — order photos as-is; the uploaded ones lead.
                    preloadedContractors: [contractor],
                    // Open with the info sheet expanded so the owner immediately sees
                    // their description, services, and credentials — not just a peek.
                    startReviewsExpanded: true,
                    previewMode: true,
                    previewProfile: profile
                )
            } else if resolved {
                unavailable
            } else {
                ProgressView().tint(.white)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            // The saved page (uploaded photos, logo, credentials) plus live Google
            // details (photo pool, rating, reviews). Either may be absent: an
            // unclaimed place has no saved page but still previews from Google; an
            // offline/unconfigured details call falls back to the saved page alone.
            profile = try? await BusinessService.profile(placeId: placeId)
            contractor = await PlacesService.fetchDetails(placeId: placeId)
                ?? profile.map(fallbackContractor)
            resolved = true
        }
    }

    // Shown only if we can build no card at all (no saved page AND no Google
    // details) — offer a way back rather than a blank screen.
    private var unavailable: some View {
        VStack(spacing: 12) {
            Image(systemName: "eye.slash")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.white.opacity(0.6))
            Text("Preview unavailable")
                .font(.h3).foregroundStyle(.white)
            Button("Close") { dismiss() }
                .font(.h4).foregroundStyle(.white)
                .padding(.top, 4)
        }
    }

    /// A card from the saved profile alone. Photos are left empty here — the
    /// gallery merges the uploaded photos itself (from `business_profiles`), so
    /// they lead whether or not Google details resolved.
    private func fallbackContractor(_ profile: BusinessService.BusinessProfile) -> Contractor {
        let name = (profile.displayName?.isEmpty == false) ? profile.displayName! : "Your business"
        return Contractor(
            id: profile.placeId,
            name: name,
            category: [],
            city: "",
            rating: 0,
            reviewCount: 0,
            responseTime: .normal,
            yearsActive: 0,
            photos: [],
            priceTiers: [],
            phone: profile.phone,
            website: profile.website,
            licenseNumber: profile.licenseNumber,
            isVerified: true,
            reviews: []
        )
    }
}
