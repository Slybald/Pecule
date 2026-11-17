import SwiftUI

struct MetricCardView: View {
    let title: String
    let value: String
    let subtitle: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(tint)

            Text(value)
                .font(AppTypography.cardValue)
                .foregroundStyle(AppColors.primaryText)

            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text(title)
                    .font(AppTypography.cardTitle)
                    .foregroundStyle(AppColors.primaryText)

                Text(subtitle)
                    .font(AppTypography.rowMeta)
                    .foregroundStyle(AppColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.lg)
        .appCardSurface()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityHint(subtitle)
    }
}

#Preview {
    MetricCardView(
        title: "Monthly Run Rate",
        value: "$28.98",
        subtitle: "Equivalent from active plans",
        systemImage: "repeat.circle.fill",
        tint: AppColors.subscriptionTint
    )
    .padding(AppSpacing.lg)
}
