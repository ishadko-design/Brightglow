import SwiftUI

/// The pill segmented control the business side runs on (Figma 1096:5241 /
/// 1096:5699 on iOS, 1140:* on web).
///
/// Shape: a gray05 capsule track, 40 high, holding equal-width segments. The
/// selected segment is a gray20 capsule with solid white text; the rest are
/// transparent with gray50 text. Segments size themselves, so the same control
/// serves the app's two tabs and the web's three.
struct SegmentedTabs<Tab: Hashable>: View {
    let tabs: [(tab: Tab, title: String)]
    @Binding var selection: Tab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tabs, id: \.tab) { item in
                let active = item.tab == selection
                Button {
                    guard !active else { return }
                    withAnimation(.easeOut(duration: 0.18)) { selection = item.tab }
                } label: {
                    Text(item.title)
                        .font(.custom("Lato-Bold", size: 18))
                        .foregroundStyle(active ? .white : AppColors.textSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(active ? AppColors.ctaSecondary : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .background(AppColors.cardSurface, in: Capsule())
        .padding(.horizontal, 16)
    }
}
