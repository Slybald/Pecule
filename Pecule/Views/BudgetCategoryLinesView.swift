import SwiftUI

/// La liste qu'ouvre une ligne de budget ou « toutes les opérations du mois ». En mode bancaire, ce sont les
/// opérations : Opérations compte les mêmes opérations et les mêmes achats saisis que le budget. En mode
/// manuel, ce sont les lignes du plan du mois, produites par le service qui calcule le montant.
struct BudgetSpendingListView: View {
    let month: Date
    let category: ExpenseCategory?
    let source: FinancialSummaryDataSource

    var body: some View {
        if source == .bank {
            // Aucun filtre de source : un achat saisi qui compte dans le total doit figurer dans la liste.
            OperationsView(month: month, category: category, source: nil, includedOnly: true)
        } else {
            BudgetCategoryLinesView(month: month, category: category)
        }
    }
}

/// Les lignes que le plan manuel du mois additionne (abonnements actifs, achats du mois), pour une catégorie ou
/// pour tout le mois. `OperationsView` ne produit ni les abonnements ni les achats rattachés : la somme de sa
/// liste n'était pas le montant de la ligne de budget (m094).
struct BudgetCategoryLinesView: View {
    let month: Date
    let category: ExpenseCategory?
    @EnvironmentObject private var appState: AppState
    @Environment(\.locale) private var locale

    var body: some View {
        let lines = appState.plannedSpendingLines(in: month, category: category)
        let total = lines.reduce(Decimal.zero) { $0 + $1.amount }.currencyRounded
        List {
            Section {
                LabeledContent(
                    AppLocalizer.string(FinancialSummaryDataSource.planned.spentLabelKey, locale: locale),
                    value: Formatters.currencyString(for: total)
                )
                .accessibilityIdentifier("budget-lines-total")
                Text(AppLocalizer.string("monthlyBudget.manualExplanation", locale: locale))
                    .font(AppTypography.rowMeta).foregroundStyle(AppColors.secondaryText)
            } header: {
                Text(Formatters.monthYearString(for: month))
            }
            if lines.isEmpty {
                Text(AppLocalizer.string("budgetLines.empty", locale: locale))
                    .foregroundStyle(AppColors.secondaryText)
                    .accessibilityIdentifier("budget-lines-empty")
            }
            ForEach(lines) { line in
                if case .purchase(let id) = line.origin, let purchase = appState.purchases.first(where: { $0.id == id }) {
                    NavigationLink { PurchaseDetailView(purchase: purchase) } label: { content(line, purchase: purchase) }
                } else {
                    content(line, purchase: nil)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(category?.displayName(locale: locale) ?? AppLocalizer.string("overview.operations.all", locale: locale))
        .accessibilityIdentifier("budget-lines-screen")
    }

    private func content(_ line: BudgetPlannerService.SpendingLine, purchase: Purchase?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(line.title).font(AppTypography.rowTitle).lineLimit(2)
                Text(subtitle(line, purchase: purchase)).font(AppTypography.rowMeta).foregroundStyle(.secondary)
            }
            Spacer()
            Text(Formatters.currencyString(for: line.amount)).font(AppTypography.rowSubtitle).monospacedDigit()
        }
        .padding(.vertical, AppSpacing.xs)
    }

    private func subtitle(_ line: BudgetPlannerService.SpendingLine, purchase: Purchase?) -> String {
        var parts: [String] = []
        // Une seule catégorie est déjà dans le titre de l'écran : on ne la répète pas.
        if category == nil { parts.append(ExpenseCategory.canonicalCategory(for: line.category).displayName(locale: locale)) }
        switch line.origin {
        case .subscription(_, let cycle):
            parts.append(AppLocalizer.string(cycle == .yearly ? "budgetLines.subscription.yearly" : "budgetLines.subscription.monthly", locale: locale))
        case .purchase:
            if let date = line.date { parts.append(Formatters.dateString(for: date)) }
            if let merchant = purchase?.merchant, !merchant.isEmpty { parts.append(merchant) }
        case .bankOperation:
            if let date = line.date { parts.append(Formatters.dateString(for: date)) }
        }
        return parts.joined(separator: " · ")
    }
}
