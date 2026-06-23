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
]

struct CategoryCard: View {
    let item: CategoryItem
    var onTap: () -> Void = {}

    var body: some View {
        Button(action: onTap) {
            GeometryReader { geo in
                ZStack(alignment: .bottomLeading) {

                    // Image — explicit pixel frame prevents scaledToFill layout overflow
                    if let img = UIImage(named: item.assetName) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                    } else {
                        Color(hex: "#353535")
                    }

                    // Gradient
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.75)],
                        startPoint: .top,
                        endPoint: .bottom
                    )

                    // Label
                    Text(item.category.rawValue)
                        .font(.h3)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                }
                .clipShape(RoundedRectangle(cornerRadius: 32))
            }
            .frame(height: 242)
        }
        .buttonStyle(PressedButtonStyle())
    }
}
