import SwiftUI

struct InsightCardView: View {
    let insight: InsightItem

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(insight.title)
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(AppColors.primaryText)

                Text(insight.message)
                    .font(AppTypography.secondaryBody)
                    .foregroundStyle(AppColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(AppSpacing.lg)
        .appCardSurface()
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch insight.type {
        case .subscription:
            return AppColors.subscriptionTint
        case .purchase:
            return AppColors.purchaseTint
        case .goal:
            return AppColors.goalTint
        case .habit:
            return AppColors.habitTint
        case .summary:
            return AppColors.secondaryText
        case .warning:
            return AppColors.warning
        case .positive:
            return AppColors.success
        }
    }

    private var systemImage: String {
        switch insight.type {
        case .subscription:
            return "repeat.circle.fill"
        case .purchase:
            return "cart.fill"
        case .goal:
            return "target"
        case .habit:
            return "checkmark.circle.fill"
        case .summary:
            return "chart.bar.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .positive:
            return "checkmark.seal.fill"
        }
    }
}

#Preview("Warning") {
    InsightCardView(
        insight: InsightItem(
            title: "Subscription Spending",
            message: "You are spending $42.00/month on active subscriptions.",
            type: .warning,
            optionalValue: "$42.00"
        )
    )
    .padding(AppSpacing.lg)
}

#Preview("Positive") {
    InsightCardView(
        insight: InsightItem(
            title: "Positive Summary",
            message: "Your current entries look balanced overall.",
            type: .positive
        )
    )
    .padding(AppSpacing.lg)
}
