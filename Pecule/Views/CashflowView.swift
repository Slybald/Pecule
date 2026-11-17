import SwiftUI

struct CashflowView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.locale) private var locale

    var body: some View {
        List {
            NavigationLink { TreasuryCalendarView() } label: {
                Text(AppLocalizer.string("treasury.title", locale: locale))
            }
            Text(AppLocalizer.string("treasury.confirmedExplanation", locale: locale))
            Text(AppLocalizer.string("treasury.estimationUnavailable", locale: locale)).foregroundStyle(.secondary)
            if let forecast = appState.cashflowForecast() {
                Section {
                    if let expected = forecast.expectedClosingBalance {
                        CashflowMetricRow(
                            title: AppLocalizer.string("cashflow.expected", locale: locale),
                            value: currency(expected),
                            tint: expected < .zero ? AppColors.error : AppColors.success,
                            isEmphasized: true
                        )
                        .accessibilityIdentifier("cashflow-expected")
                        CashflowMetricRow(
                            title: AppLocalizer.string("cashflow.confidence", locale: locale),
                            value: confidenceText(forecast.confidence)
                        )
                    } else {
                        // No amount and no range: only why, in one sentence.
                        Text(AppLocalizer.string(forecast.closingBalanceAvailability == .unknownBalance
                                                 ? "dashboard.metrics.cashflow.noBalance" : "cashflow.forecastUnavailable", locale: locale))
                            .font(AppTypography.secondaryBody)
                            .foregroundStyle(AppColors.secondaryText)
                            .accessibilityIdentifier("cashflow-expected")
                    }
                } header: {
                    Text(Formatters.monthYearString(for: forecast.month.start))
                } footer: {
                    if forecast.expectedClosingBalance != nil {
                        Text(AppLocalizer.format("cashflow.footer %lld %lld", locale: locale, forecast.completeMonthsUsed, forecast.remainingDays))
                    }
                }

                Section {
                    CashflowMetricRow(title: AppLocalizer.string("cashflow.openingBalance", locale: locale), value: currency(forecast.openingBalance))
                    CashflowMetricRow(title: AppLocalizer.string("cashflow.remainingIncome", locale: locale), value: "+" + Formatters.currencyString(for: forecast.remainingIncome))
                    CashflowMetricRow(title: AppLocalizer.string("cashflow.remainingCharges", locale: locale), value: "−" + Formatters.currencyString(for: forecast.remainingFixedCharges))

                } header: {
                    Text(AppLocalizer.string("cashflow.section.components", locale: locale))
                }

                if !forecast.upcomingCharges.isEmpty {
                    Section {
                        ForEach(forecast.upcomingCharges) { charge in
                            HStack {
                                VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                                    Text(charge.name)
                                        .font(AppTypography.rowTitle)
                                        .foregroundStyle(AppColors.primaryText)
                                    Text(Formatters.dateString(for: charge.date))
                                        .font(AppTypography.rowMeta)
                                        .foregroundStyle(AppColors.secondaryText)
                                }
                                Spacer()
                                Text(Formatters.currencyString(for: charge.amount))
                                    .font(AppTypography.rowTitle.weight(.semibold))
                                    .foregroundStyle(AppColors.primaryText)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    } header: {
                        Text(AppLocalizer.string("cashflow.section.upcoming", locale: locale))
                    }
                }
            } else {
                Text(AppLocalizer.string("cashflow.empty", locale: locale))
                    .font(AppTypography.secondaryBody)
                    .foregroundStyle(AppColors.secondaryText)
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppColors.groupedBackground.ignoresSafeArea())
        .navigationTitle(AppLocalizer.string("cashflow.title", locale: locale))
        .accessibilityIdentifier("cashflow-screen")
    }

    private func currency(_ value: Decimal?) -> String {
        value.map { Formatters.currencyString(for: $0) } ?? AppLocalizer.string("bankAccount.balance.unknown", locale: locale)
    }

    private func confidenceText(_ confidence: CashflowForecast.Confidence) -> String {
        switch confidence {
        case .low: AppLocalizer.string("cashflow.confidence.low", locale: locale)
        case .medium: AppLocalizer.string("cashflow.confidence.medium", locale: locale)
        case .high: AppLocalizer.string("cashflow.confidence.high", locale: locale)
        }
    }
}

private struct CashflowMetricRow: View {
    let title: String
    let value: String
    var tint: Color = AppColors.primaryText
    var isEmphasized = false

    var body: some View {
        HStack {
            Text(title)
                .font(isEmphasized ? AppTypography.rowTitle : AppTypography.rowSubtitle)
                .foregroundStyle(isEmphasized ? AppColors.primaryText : AppColors.secondaryText)
            Spacer()
            Text(value)
                .font(isEmphasized ? AppTypography.cardTitle : AppTypography.rowTitle)
                .foregroundStyle(tint)
                .privacySensitive()
        }
        .accessibilityElement(children: .combine)
    }
}
