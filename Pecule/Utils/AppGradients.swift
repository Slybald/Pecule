import SwiftUI

// One gradient in the whole app: the area under a chart line. Surfaces, strokes and text stay flat.
enum AppGradients {
    static let chartArea = LinearGradient(
        colors: [AppColors.accent.opacity(0.24), AppColors.accent.opacity(0)],
        startPoint: .top,
        endPoint: .bottom
    )

    // Legacy names kept during the migration; both resolve to flat accent.
    static let ai = LinearGradient(colors: [AppColors.accent, AppColors.accent], startPoint: .leading, endPoint: .trailing)
    static let accent = LinearGradient(colors: [AppColors.accent, AppColors.accent], startPoint: .leading, endPoint: .trailing)

    static func color(for category: ExpenseCategory) -> Color {
        AppColors.category(category)
    }
}
