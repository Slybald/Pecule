import SwiftUI

// One primary responsibility per destination.
struct RootTabView: View {
    // Nommé « Destination » et non « Tab » : le type imbriqué masquerait le `Tab` de SwiftUI,
    // que la barre d'onglets d'iOS 26 exige pour exposer un identifiant d'accessibilité.
    enum Destination: Hashable {
        case today
        case accounts
        case spending
        case goals
        case operations
    }

    @StateObject private var navigation = AppNavigation()
    @EnvironmentObject private var appState: AppState
    @Environment(\.locale) private var locale

    var body: some View {
        TabView(selection: $navigation.selectedTab) {
            Tab(value: Destination.today) {
                NavigationStack { DashboardView() }
            } label: {
                Label(AppLocalizer.string("tab.today", locale: locale), systemImage: "sun.max.fill")
            }
            .accessibilityIdentifier("root-tab-today")

            Tab(value: Destination.operations) {
                NavigationStack { OperationsView() }
            } label: {
                Label(AppLocalizer.string("operations.title", locale: locale), systemImage: "list.bullet.rectangle")
            }
            .accessibilityIdentifier("root-tab-operations")

            Tab(value: Destination.spending) {
                NavigationStack { SpendingView() }
            } label: {
                Label(AppLocalizer.string("tab.spending", locale: locale), systemImage: "chart.bar.fill")
            }
            .accessibilityIdentifier("root-tab-spending")

            Tab(value: Destination.goals) {
                NavigationStack { GoalsView() }
            } label: {
                Label(AppLocalizer.string("tab.goals", locale: locale), systemImage: "target")
            }
            .accessibilityIdentifier("root-tab-goals")

            Tab(value: Destination.accounts) {
                NavigationStack { BankAccountsView(bankSync: appState.bankSync) }
            } label: {
                Label(AppLocalizer.string("tab.accounts", locale: locale), systemImage: "building.columns.fill")
            }
            .accessibilityIdentifier("root-tab-accounts")
        }
        .tint(AppColors.accent)
        .environmentObject(navigation)
    }
}

#Preview {
    RootTabView()
        .environmentObject(LocalizationManager())
        .environmentObject(AppState.preview)
}
