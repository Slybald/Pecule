import AppIntents
import Foundation

enum PeculeIntentError: Error, CustomLocalizedStringResourceConvertible {
    case invalidAmount
    case emptyLabel

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .invalidAmount: "intent.error.invalidAmount"
        case .emptyLabel: "intent.error.emptyLabel"
        }
    }
}

enum IntentExpenseCategory: String, CaseIterable, AppEnum {
    case subscriptions, insurance, groceries, fuel, transport, housing, health, leisure, shopping, education, other
    var storageValue: String { ExpenseCategory(rawValue: rawValue)?.storageValue ?? "Other" }

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "intent.category.type")
    static let caseDisplayRepresentations: [IntentExpenseCategory: DisplayRepresentation] = [
        .subscriptions: "expenseCategory.subscriptions",
        .insurance: "expenseCategory.insurance",
        .groceries: "expenseCategory.groceries",
        .fuel: "expenseCategory.fuel",
        .transport: "expenseCategory.transport",
        .housing: "expenseCategory.housing",
        .health: "expenseCategory.health",
        .leisure: "expenseCategory.leisure",
        .shopping: "expenseCategory.shopping",
        .education: "expenseCategory.education",
        .other: "expenseCategory.other",
    ]
}

// "Ajoute une dépense" from Siri or Shortcuts, without opening the app.
struct LogPurchaseIntent: AppIntent {
    static let title: LocalizedStringResource = "intent.logPurchase.title"
    static let description = IntentDescription("intent.logPurchase.description")
    static let openAppWhenRun = false
    // Solde et saisie exigent un iPhone déverrouillé, même via Siri.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "intent.parameter.amount", requestValueDialog: "intent.parameter.amount.ask")
    var amount: Double

    @Parameter(title: "intent.parameter.label", requestValueDialog: "intent.parameter.label.ask")
    var label: String

    @Parameter(title: "intent.parameter.category", default: .other)
    var category: IntentExpenseCategory

    static var parameterSummary: some ParameterSummary {
        Summary("Ajouter \(\.$amount) € pour \(\.$label)") {
            \.$category
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard amount > 0 else {
            throw PeculeIntentError.invalidAmount
        }
        let title = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw PeculeIntentError.emptyLabel
        }
        let value = Decimal(amount).currencyRounded
        try AppIntentSupport.store().addPurchase(title: title, amount: value, date: Date(), category: category.storageValue, merchant: "", notes: nil)
        AppIntentSupport.notifyChange()
        return .result(dialog: IntentDialog("intent.logPurchase.done \(Formatters.currencyString(for: value)) \(title)"))
    }
}

// "Quel est mon solde" reads the cached balances; no bank call is made.
struct TotalBalanceIntent: AppIntent {
    static let title: LocalizedStringResource = "intent.balance.title"
    static let description = IntentDescription("intent.balance.description")
    static let openAppWhenRun = false
    // Solde et saisie exigent un iPhone déverrouillé, même via Siri.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Double> {
        let accounts = try AppIntentSupport.store().loadSnapshot().externalAccounts
        let balances = accounts.filter { $0.isIncludedInTotals && $0.currencyCode == "EUR" }.compactMap(\.balance)
        guard !balances.isEmpty else {
            return .result(value: 0, dialog: IntentDialog("intent.balance.none"))
        }
        let total = balances.reduce(.zero, +).currencyRounded
        return .result(
            value: NSDecimalNumber(decimal: total).doubleValue,
            dialog: IntentDialog("intent.balance.total \(Formatters.currencyString(for: total)) \(balances.count)")
        )
    }
}

struct PeculeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LogPurchaseIntent(),
            phrases: [
                "Ajoute une dépense dans \(.applicationName)",
                "Enregistre un achat dans \(.applicationName)",
            ],
            shortTitle: "intent.logPurchase.title",
            systemImageName: "cart.badge.plus"
        )
        AppShortcut(
            intent: TotalBalanceIntent(),
            phrases: [
                "Quel est mon solde dans \(.applicationName)",
                "Mon solde \(.applicationName)",
            ],
            shortTitle: "intent.balance.shortTitle",
            systemImageName: "building.columns"
        )
    }
}
