import SwiftUI

struct HomeScreen: View {
    @State private var searchText = ""
    @State private var goSwipe: Category? = nil
    @State private var sheetExpanded = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {

                // Dark background
                AppColors.bg.ignoresSafeArea()

                // Main scrollable content
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {

                        // Header
                        HStack {
                            Text("Categories")
                                .font(.h2)
                                .foregroundStyle(.white)
                            Spacer()
                            Button(action: {}) {
                                Image(systemName: "person.circle.fill")
                                    .font(.system(size: 26))
                                    .foregroundStyle(.white.opacity(0.7))
                                    .iconTapTarget()
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 60)

                        // 2-column grid — Figma: row gap 16, card gap 12, h-padding 24
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: 12),
                                GridItem(.flexible(), spacing: 12)
                            ],
                            spacing: 16
                        ) {
                            ForEach(categoryItems) { item in
                                CategoryCard(item: item) {
                                    goSwipe = item.category
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 120)
                    }
                }

                // Search bar pinned at bottom
                HStack(alignment: .center, spacing: 12) {
                    TextField("Describe what you need…", text: $searchText, axis: .vertical)
                        .font(.bodyLight)
                        .foregroundStyle(.white)
                        .tint(AppColors.accentStart)
                        .lineLimit(1...5)
                    HStack(spacing: 0) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 22))
                            .foregroundStyle(.white.opacity(0.5))
                            .iconTapTarget()
                        Image(systemName: "mic")
                            .font(.system(size: 22))
                            .foregroundStyle(.white.opacity(0.5))
                            .iconTapTarget()
                    }

                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(minHeight: 60)
                .background {
                    ZStack {
                        Color.clear.background(.ultraThinMaterial)
                        AppColors.searchBg
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 32))
                .overlay(RoundedRectangle(cornerRadius: 32).stroke(AppColors.searchBorder, lineWidth: 1.5))
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .navigationBarHidden(true)
            .navigationDestination(isPresented: Binding(
                get: { goSwipe != nil },
                set: { if !$0 { goSwipe = nil } }
            )) {
                SwipeScreen(category: goSwipe?.rawValue ?? "")
            }
        }
        .preferredColorScheme(.dark)
    }
}
