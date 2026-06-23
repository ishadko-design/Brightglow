import SwiftUI

struct CategoriesSheet: View {
    var onCategoryTap: (Category) -> Void
    var onProfileTap: () -> Void
    /// Updated on every scroll frame — true only when content is at the very top.
    @Binding var isScrolledToTop: Bool

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {

                // Header row
                HStack {
                    Text("Categories")
                        .font(.h2)
                        .foregroundStyle(AppColors.textPrimary)
                    Spacer()
                }
                .padding(.horizontal, 16)

                // 2-column grid
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12)
                    ],
                    spacing: 16
                ) {
                    ForEach(categoryItems) { item in
                        CategoryCard(item: item) {
                            onCategoryTap(item.category)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 160)
            }
            .padding(.top, 4)
        }
        // onScrollGeometryChange fires on every scroll frame (not just layout passes),
        // giving us a real-time, accurate "is at top" signal.
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y <= 0
        } action: { _, atTop in
            isScrolledToTop = atTop
        }
    }
}
