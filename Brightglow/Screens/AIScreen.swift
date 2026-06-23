import SwiftUI

struct AIScreen: View {
    var initialText: String? = nil

    var body: some View {
        ZStack {
            AppColors.bgPrimary.ignoresSafeArea()
            VStack {
                Spacer()
                Text("AIScreen")
                    .font(.bodySmall)
                    .foregroundStyle(AppColors.textSecondary)
                Spacer()
            }
        }

    }
}

#Preview {
    NavigationStack {
        AIScreen()
    }
}
