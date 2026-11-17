import SwiftUI

struct FinancialHealthView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.locale) private var locale

    var body: some View {
        let score = appState.financialHealthScore()
        List {
            Section {
                HStack(alignment: .firstTextBaseline, spacing: AppSpacing.md) {
                    Text(score.grade?.rawValue ?? "–")
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .foregroundStyle(AppGradients.accent)
                    VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                        Text(score.total.map { AppLocalizer.format("health.total %lld", locale: locale, $0) } ?? AppLocalizer.string("health.unmeasured", locale: locale))
                            .font(AppTypography.rowTitle)
                            .foregroundStyle(AppColors.primaryText)
                        if let weakest = score.weakestComponent {
                            Text(AppLocalizer.format("health.lever %@", locale: locale, componentName(weakest.kind)))
                                .font(AppTypography.rowMeta)
                                .foregroundStyle(AppColors.secondaryText)
                        }
                    }
                }
                .padding(.vertical, AppSpacing.xs)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("health-grade")
            } footer: {
                Text(AppLocalizer.string("health.footer", locale: locale))
            }

            Section {
                ForEach(score.components) { component in
                    VStack(alignment: .leading, spacing: AppSpacing.sm) {
                        HStack {
                            Text(componentName(component.kind))
                                .font(AppTypography.rowTitle)
                                .foregroundStyle(AppColors.primaryText)
                            Spacer()
                            Text(component.score.map { "\($0)" } ?? "–")
                                .font(AppTypography.rowTitle.weight(.semibold))
                                .foregroundStyle(tint(for: component))
                            Text(AppLocalizer.format("health.weight %lld", locale: locale, Int(component.weight * 100)))
                                .font(AppTypography.rowMeta)
                                .foregroundStyle(AppColors.secondaryText)
                        }
                        ProgressView(value: Double(component.score ?? 0), total: 100)
                            .tint(tint(for: component))
                            .appAnimation(value: component.score)
                        Text(detail(for: component))
                            .font(AppTypography.rowMeta)
                            .foregroundStyle(AppColors.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, AppSpacing.xs)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("health-component-\(component.kind.rawValue)")
                }
            } header: {
                Text(AppLocalizer.string("health.section.components", locale: locale))
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppColors.groupedBackground.ignoresSafeArea())
        .navigationTitle(AppLocalizer.string("health.title", locale: locale))
        .accessibilityIdentifier("health-screen")
    }

    private func componentName(_ kind: FinancialHealthComponent.Kind) -> String {
        AppLocalizer.string("health.component.\(kind.rawValue)", locale: locale)
    }

    private func tint(for component: FinancialHealthComponent) -> Color {
        guard let score = component.score else {
            return AppColors.neutral
        }
        switch score {
        case 80...: return AppColors.success
        case 50 ..< 80: return AppColors.warning
        default: return AppColors.error
        }
    }

    private func detail(for component: FinancialHealthComponent) -> String {
        guard let measured = component.measured else {
            return AppLocalizer.string("health.unmeasured", locale: locale)
        }
        let measuredText = component.kind == .cushion
            ? AppLocalizer.format("health.measured.months %@", locale: locale, String(format: "%.1f", locale: locale, measured))
            : AppLocalizer.format("health.measured.percent %@", locale: locale, Formatters.percentString(for: measured))
        guard let lever = component.leverAmount else {
            return measuredText + " · " + AppLocalizer.string("health.advice.ok", locale: locale)
        }
        return measuredText + " · " + AppLocalizer.format("health.advice.\(component.kind.rawValue) %@", locale: locale, Formatters.currencyString(for: lever))
    }
}
