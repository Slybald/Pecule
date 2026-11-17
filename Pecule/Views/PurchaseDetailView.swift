import SwiftUI

struct PurchaseDetailView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.locale) private var locale

    let purchase: Purchase

    @State private var isPresentingEditSheet = false

    private let financialCalculator = FinancialCalculatorService()

    var body: some View {
        List {
            Section(AppLocalizer.string("Purchase", locale: locale)) {
                detailRow(title: AppLocalizer.string("Amount", locale: locale), value: Formatters.currencyString(for: purchase.amount))
                detailRow(title: AppLocalizer.string("Merchant", locale: locale), value: purchase.merchant)
                detailRow(title: AppLocalizer.string("Category", locale: locale), value: purchase.category)
                detailRow(title: AppLocalizer.string("Date", locale: locale), value: Formatters.dateString(for: purchase.date))

                if let notes = purchase.notes, !notes.isEmpty {
                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Text(AppLocalizer.string("Notes", locale: locale))
                            .font(AppTypography.rowSubtitle.weight(.semibold))
                            .foregroundStyle(AppColors.secondaryText)

                        Text(notes)
                            .font(AppTypography.body)
                            .foregroundStyle(AppColors.primaryText)
                    }
                    .padding(.vertical, AppSpacing.xxs)
                }
            }

            Section {
                detailRow(
                    title: AppLocalizer.string("Cost per Day", locale: locale),
                    value: Formatters.currencyString(for: financialCalculator.costPerDay(purchase))
                )
                detailRow(
                    title: AppLocalizer.string("1 Month", locale: locale),
                    value: Formatters.currencyString(for: financialCalculator.costOverTime(purchase, months: 1))
                )
                detailRow(
                    title: AppLocalizer.string("6 Months", locale: locale),
                    value: Formatters.currencyString(for: financialCalculator.costOverTime(purchase, months: 6))
                )
                detailRow(
                    title: AppLocalizer.string("12 Months", locale: locale),
                    value: Formatters.currencyString(for: financialCalculator.costOverTime(purchase, months: 12))
                )
            } header: {
                Text(AppLocalizer.string("Monthly Repeat Projection", locale: locale))
            } footer: {
                Text(AppLocalizer.string("Assumes this purchase would repeat every month.", locale: locale))
                    .font(AppTypography.rowMeta)
                    .foregroundStyle(AppColors.secondaryText)
            }
        }
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("purchase-detail-screen")
        .navigationTitle(purchase.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(AppLocalizer.string("Edit", locale: locale)) {
                    isPresentingEditSheet = true
                }
                .accessibilityLabel(AppLocalizer.string("Edit Purchase", locale: locale))
                .accessibilityIdentifier("purchase-detail-edit-button")
            }
        }
        .sheet(isPresented: $isPresentingEditSheet) {
            NavigationStack {
                PurchaseFormView(purchase: purchase)
            }
            .environmentObject(appState)
        }
    }

    @ViewBuilder
    private func detailRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(AppTypography.rowSubtitle)
                .foregroundStyle(AppColors.secondaryText)

            Spacer()

            Text(value)
                .font(AppTypography.rowTitle)
                .foregroundStyle(AppColors.primaryText)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, AppSpacing.xxs)
    }
}

#Preview {
    let previewState = AppState.preview

    return NavigationStack {
        PurchaseDetailView(purchase: previewState.purchases.first!)
            .environmentObject(previewState)
    }
}
