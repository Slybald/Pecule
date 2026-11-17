import SwiftUI

// Print layout: black on white, no glass, sized by the caller to an A4 page.
struct MonthlyReportView: View {
    let report: MonthlyReport

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Pécule · Rapport mensuel")
                    .font(.system(size: 22, weight: .bold))
                Text(Formatters.monthYearString(for: report.month))
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }

            reportSection("Résumé") {
                row("Revenus estimés", Formatters.currencyString(for: report.summary.totalEstimatedIncome))
                row("Charges fixes", Formatters.currencyString(for: report.summary.fixedCharges))
                row("Dépenses variables", Formatters.currencyString(for: report.summary.variableExpenses))
                row("Reste à vivre", Formatters.currencyString(for: report.summary.remainingToLive), emphasized: true)
                if let balance = report.totalBalance {
                    row("Solde des comptes", Formatters.currencyString(for: balance))
                }
                row("Source des montants", report.summary.dataSource == .bank ? "Relevés bancaires" : "Prévisionnel")
            }

            if !report.budgetRows.isEmpty {
                reportSection("Budgets par catégorie") {
                    ForEach(report.budgetRows) { budget in
                        row(
                            budget.category.displayName(locale: Locale(identifier: "fr_FR")),
                            budget.plannedAmount.map { "\(Formatters.currencyString(for: budget.spentAmount)) / \(Formatters.currencyString(for: $0))" }
                                ?? Formatters.currencyString(for: budget.spentAmount)
                        )
                    }
                }
            }

            // No forecast figure while the month-end balance is withheld; the known remaining charges are not an estimate.
            if let forecast = report.forecast, forecast.expectedClosingBalance != nil || !forecast.upcomingCharges.isEmpty {
                reportSection("Trésorerie") {
                    if let expected = forecast.expectedClosingBalance {
                        row("Solde prévu fin de mois", Formatters.currencyString(for: expected), emphasized: true)
                        if let worst = forecast.worstClosingBalance, let best = forecast.bestClosingBalance {
                            row("Fourchette", "\(Formatters.currencyString(for: worst)) – \(Formatters.currencyString(for: best))")
                        }
                    }
                    row("Prélèvements restants", Formatters.currencyString(for: forecast.remainingFixedCharges))
                }
            }

            reportSection("Santé financière") {
                row("Note", report.health.grade.map { grade in report.health.total.map { "\(grade.rawValue) · \($0)/100" } ?? grade.rawValue } ?? "Non mesurée", emphasized: true)
                ForEach(report.health.components) { component in
                    row(componentName(component.kind), component.score.map { "\($0)/100" } ?? "non mesuré")
                }
            }

            Spacer(minLength: 0)

            Text("Généré par Pécule le \(Formatters.dateString(for: Date())). Données locales, aucune transmission.")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white)
        .foregroundStyle(Color.black)
        .environment(\.colorScheme, .light)
    }

    private func reportSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func row(_ label: String, _ value: String, emphasized: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11, weight: emphasized ? .semibold : .regular))
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: emphasized ? .semibold : .regular))
        }
    }

    private func componentName(_ kind: FinancialHealthComponent.Kind) -> String {
        switch kind {
        case .savings: "Épargne"
        case .fixedCharges: "Charges fixes"
        case .margin: "Marge du mois"
        case .cushion: "Coussin de sécurité"
        }
    }
}
