import SwiftUI
import Combine

/// App-wide business state: whether the signed-in user owns a business, the
/// requests to it, and the selected business's page (`business_profiles`).
///
/// Injected at the app root (see `RootNavigator`) so the header entry point,
/// deep-link routing, and the dashboard all read one source of truth. Loaded once
/// on sign-in; reloaded when the dashboard opens.
@MainActor
final class BusinessStore: ObservableObject {
    @Published private(set) var businesses: [BusinessService.OwnedBusiness] = []
    @Published private(set) var isOwner = false
    @Published private(set) var loading = false
    @Published private(set) var loadError = false
    /// True once the first ownership resolution has finished (success or failure).
    /// Deep-link routing waits on this so a cold-start link routes to the right
    /// place (business dashboard vs customer inbox) instead of racing the load.
    @Published private(set) var didLoad = false

    /// The business currently in focus in the dashboard, and its saved page (nil
    /// until loaded, or when the business hasn't created one yet).
    @Published var selectedPlaceId: String?
    @Published private(set) var profile: BusinessService.BusinessProfile?

    /// After a business sends a reply in a thread, this holds that thread's
    /// place_id so the dashboard can nudge them to complete their page on the way
    /// back. Consumed once; `nudgedThisSession` keeps it from repeating.
    @Published var pendingReplyNudgePlaceId: String?
    private var nudgedThisSession: Set<String> = []

    var selected: BusinessService.OwnedBusiness? {
        businesses.first { $0.placeId == selectedPlaceId }
    }

    // MARK: - Loading

    /// Fetch the businesses this user can manage. Best-effort: a failure leaves
    /// `isOwner` false so the app simply shows no business affordances. Preserves
    /// the current selection when possible, else selects the first business.
    func load() async {
        loading = true
        loadError = false
        do {
            let list = try await BusinessService.myBusinesses()
            businesses = list
            isOwner = !list.isEmpty
            loading = false
            didLoad = true
            // Keep a valid selection.
            if selectedPlaceId == nil || !list.contains(where: { $0.placeId == selectedPlaceId }) {
                await select(list.first?.placeId)
            }
        } catch {
            #if DEBUG
            print("🏢 business load failed — \(error)")
            #endif
            loading = false
            loadError = true
            didLoad = true
        }
    }

    /// Reset on sign-out so a different account doesn't inherit this one's state.
    func reset() {
        businesses = []
        isOwner = false
        didLoad = false
        selectedPlaceId = nil
        profile = nil
        pendingReplyNudgePlaceId = nil
        nudgedThisSession.removeAll()
    }

    // MARK: - Selection + profile

    /// Focus a business and load its page. Falls back to a page seeded from the
    /// lead (name/website) when nothing is saved yet, so the editor opens filled.
    func select(_ placeId: String?) async {
        selectedPlaceId = placeId
        guard let placeId, let biz = businesses.first(where: { $0.placeId == placeId }) else {
            profile = nil
            return
        }
        do {
            profile = try await BusinessService.profile(placeId: placeId)
                ?? BusinessService.BusinessProfile(seededFrom: biz)
        } catch {
            #if DEBUG
            print("🏢 profile load failed for \(placeId) — \(error)")
            #endif
            profile = BusinessService.BusinessProfile(seededFrom: biz)
        }
    }

    /// Adopt an edited page after a successful save so the dashboard reflects it
    /// (completeness bar, accepting-work toggle) without a round trip.
    func applySavedProfile(_ updated: BusinessService.BusinessProfile) {
        profile = updated
    }

    /// Flip the "accepting new work" flag from the dashboard and persist it right
    /// away — the dashboard has no Save button (unlike the editor), mirroring the
    /// web portal's header toggle. Optimistic: the published `profile` updates
    /// immediately and reverts if the write fails. No-op until a profile is loaded.
    @discardableResult
    func setAcceptingWork(_ on: Bool) async -> Bool {
        guard var updated = profile, updated.acceptingWork != on else { return true }
        let previous = updated.acceptingWork
        updated.acceptingWork = on
        profile = updated                       // optimistic
        do {
            var toSave = updated
            toSave.normalizeForSave()
            try await BusinessService.saveProfile(toSave)
            profile = toSave
            return true
        } catch {
            #if DEBUG
            print("🏢 accepting-work save failed — \(error)")
            #endif
            var reverted = profile
            reverted?.acceptingWork = previous
            profile = reverted                  // snap back so the toggle reflects reality
            return false
        }
    }

    // MARK: - Nudge

    /// A business just visited one of its request threads — arm the page-completion
    /// nudge so the inbox can prompt them to finish their page when they exit the
    /// conversation and return to the list (fires once per session, only if
    /// incomplete).
    func armPageNudge(placeId: String?) {
        guard let placeId else { return }
        pendingReplyNudgePlaceId = placeId
    }

    /// True once — when a reply was just sent to this place and its page is still
    /// incomplete. Marks it shown so the prompt doesn't repeat this session.
    func consumeNudge(for placeId: String?) -> Bool {
        guard let placeId,
              pendingReplyNudgePlaceId == placeId,
              !nudgedThisSession.contains(placeId),
              let profile,
              !BusinessService.isComplete(profile)
        else { return false }
        pendingReplyNudgePlaceId = nil
        nudgedThisSession.insert(placeId)
        return true
    }
}
