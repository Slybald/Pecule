import SwiftUI

struct AIAdvisorCardView: View {
    @ObservedObject var aiAdvisor: AIAdvisorService
    let appState: AppState
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack {
                Label(AppLocalizer.string("aiAdvisor.title", locale: locale), systemImage: "apple.intelligence")
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(AppColors.accent)

                Spacer()

                if case .loading = aiAdvisor.state {
                    ProgressView()
                        .tint(AppColors.accent)
                } else {
                    Button {
                        Task { await aiAdvisor.generateAdvice(from: appState) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(AppColors.secondaryText)
                    }
                    .accessibilityLabel(AppLocalizer.string("aiAdvisor.refresh", locale: locale))
                    .accessibilityIdentifier("dashboard-ai-advisor-refresh-button")
                }
            }

            switch aiAdvisor.state {
            case .idle:
                Text(AppLocalizer.string("aiAdvisor.idle.message", locale: locale))
                    .font(AppTypography.secondaryBody)
                    .foregroundStyle(AppColors.secondaryText)
            case .loading:
                Text(AppLocalizer.string("aiAdvisor.loading.message", locale: locale))
                    .font(AppTypography.secondaryBody)
                    .foregroundStyle(AppColors.secondaryText)
                SkeletonView(lines: 3)
                    .accessibilityIdentifier("dashboard-ai-advisor-skeleton")
            case .available(let insight):
                HStack(alignment: .top, spacing: AppSpacing.md) {
                    Text(insight.emoji)
                        .font(.title)

                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Text(insight.title)
                            .font(AppTypography.rowTitle.weight(.semibold))
                            .foregroundStyle(AppColors.primaryText)

                        Text(insight.advice)
                            .font(AppTypography.secondaryBody)
                            .foregroundStyle(AppColors.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            case .unavailable(let reason):
                HStack(alignment: .top, spacing: AppSpacing.md) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppColors.warning)

                    Text(reason.localizedDescription)
                        .font(AppTypography.secondaryBody)
                        .foregroundStyle(AppColors.secondaryText)
                }
            }
        }
        .padding(AppSpacing.lg)
        .appCardSurface()
        .accessibilityIdentifier("dashboard-ai-advisor-card")
    }
}
