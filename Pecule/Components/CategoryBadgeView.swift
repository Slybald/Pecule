import SwiftUI

// 28 pt circle, category tint at 14 %, symbol in the category colour. Colour is never the only channel.
struct CategoryBadgeView: View {
    let category: ExpenseCategory
    var size: CGFloat = 28
    @Environment(\.locale) private var locale

    var body: some View {
        Image(systemName: AppColors.categorySymbol(category))
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(AppColors.category(category))
            .frame(width: size, height: size)
            .background(AppColors.category(category).opacity(0.14), in: Circle())
            .accessibilityLabel(category.displayName(locale: locale))
    }
}
