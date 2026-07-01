import SwiftUI

struct CategoryItem: Identifiable {
    var id: Category { category }
    let category: Category
    let assetName: String
}

let categoryItems: [CategoryItem] = [
    CategoryItem(category: .plumbing,     assetName: "fig_plumbing"),
    CategoryItem(category: .electrical,   assetName: "fig_electrical"),
    CategoryItem(category: .painting,     assetName: "fig_painting"),
    CategoryItem(category: .hvac,         assetName: "fig_hvac"),
    CategoryItem(category: .carpentry,    assetName: "fig_carpentry"),
    CategoryItem(category: .roofing,      assetName: "fig_roofing"),
    CategoryItem(category: .flooring,     assetName: "fig_flooring"),
    CategoryItem(category: .windowsDoors, assetName: "fig_windows"),
    CategoryItem(category: .landscaping,  assetName: "fig_landscaping"),
    CategoryItem(category: .pestControl,  assetName: "fig_pest"),
]

/// Generic image card used across the landing sheet (verticals) and the
/// category grids (home + auto): a photo — or a fallback colour when the asset
/// is missing/blank — under a gradient with a bottom-left label.
struct TaskCard: View {
    let title: String
    let assetName: String
    var height: CGFloat = 240
    var onTap: () -> Void = {}

    var body: some View {
        Button(action: onTap) {
            GeometryReader { geo in
                ZStack(alignment: .bottomLeading) {

                    // Image — explicit pixel frame prevents scaledToFill layout overflow
                    if let img = UIImage(named: assetName) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                    } else {
                        AppColors.cardFallback
                    }

                    // Gradient
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.75)],
                        startPoint: .top,
                        endPoint: .bottom
                    )

                    // Label
                    Text(title)
                        .font(.h3)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                }
                .clipShape(RoundedRectangle(cornerRadius: 32))
            }
            .frame(height: height)
        }
        .buttonStyle(PressedButtonStyle())
    }
}

/// Thin wrapper so existing call sites (home grid) keep passing a `CategoryItem`.
struct CategoryCard: View {
    let item: CategoryItem
    var onTap: () -> Void = {}

    var body: some View {
        TaskCard(title: item.category.rawValue, assetName: item.assetName, onTap: onTap)
    }
}
