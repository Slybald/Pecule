import SwiftUI

struct RecommendationCardView: View {
    let recommendation: RecommendationItem
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                HStack(alignment: .firstTextBaseline) {
                    Text(recommendation.title)
                        .font(AppTypography.rowTitle)
                        .foregroundStyle(AppColors.primaryText)

                    Spacer(minLength: AppSpacing.xs)

                    Text(priorityTitle)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, AppSpacing.sm)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(priorityColor)
                        )
                }

                Text(recommendation.message)
                    .font(AppTypography.secondaryBody)
                    .foregroundStyle(AppColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if let impact = recommendation.estimatedImpact {
                    Text(AppLocalizer.format("Potential impact: %@", locale: locale, impact))
                        .font(AppTypography.rowMeta)
                        .foregroundStyle(AppColors.accent)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(AppSpacing.lg)
        .appCardSurface()
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch recommendation.type {
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
        case .positive:
            return AppColors.success
        }
    }

    private var systemImage: String {
        switch recommendation.type {
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
        case .positive:
            return "checkmark.seal.fill"
        }
    }

    private var priorityColor: Color {
        switch recommendation.priority {
        case .high:
            return AppColors.error
        case .medium:
            return AppColors.warning
        case .low:
            return AppColors.success
        }
    }

    private var priorityTitle: String {
        switch recommendation.priority {
        case .high:
            return AppLocalizer.string("recommendation.priority.high", locale: locale)
        case .medium:
            return AppLocalizer.string("recommendation.priority.medium", locale: locale)
        case .low:
            return AppLocalizer.string("recommendation.priority.low", locale: locale)
        }
    }
}

#Preview("High Priority") {
    RecommendationCardView(
        recommendation: RecommendationItem(
            title: "Expensive Subscription",
            message: "\"Netflix\" is a high-cost subscription. Consider reviewing or suspending it.",
            type: .subscription,
            priority: .high,
            estimatedImpact: "$191.88"
        )
    )
    .padding(AppSpacing.lg)
}

#Preview("Medium Priority") {
    RecommendationCardView(
        recommendation: RecommendationItem(
            title: "Goal Behind Schedule",
            message: "Your goal \"Summer Vacation\" is progressing slowly. Consider contributing about $265/month.",
            type: .goal,
            priority: .medium,
            estimatedImpact: "$265.00"
        )
    )
    .padding(AppSpacing.lg)
}

#Preview("Positive") {
    RecommendationCardView(
        recommendation: RecommendationItem(
            title: "Looking Good",
            message: "No urgent financial changes stand out right now. Keep up the good work!",
            type: .positive,
            priority: .low
        )
    )
    .padding(AppSpacing.lg)
}
