import SwiftUI

// "Où part l'argent ?" — budgets are the decision, purchases and subscriptions are the inputs.
struct SpendingView: View {
    @EnvironmentObject private var navigation: AppNavigation
    @Environment(\.locale) private var locale

    var body: some View {
        Group {
            switch navigation.spendingSegment {
            case .budgets:
                BudgetRulesView()
            case .purchases:
                PurchasesView()
            case .subscriptions:
                SubscriptionsView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    ForEach(AppNavigation.SpendingSegment.allCases) { segment in
                        Button(AppLocalizer.string("spending.segment." + segment.rawValue, locale: locale)) { navigation.spendingSegment = segment }
                            .accessibilityIdentifier("spending-segment-" + segment.rawValue)
                    }
                } label: { Label(AppLocalizer.string("budget.manage", locale: locale), systemImage: "ellipsis.circle") }
                .accessibilityIdentifier("budget-manage-menu")
            }
        }
        .onChange(of: navigation.pendingRoute, initial: true) { _, route in
            if let segment = route?.spendingSegment {
                navigation.spendingSegment = segment
            }
        }
        .navigationTitle(AppLocalizer.string("spending.segment.\(navigation.spendingSegment.rawValue)", locale: locale))
        .navigationBarTitleDisplayMode(.inline)
    }
}
