import XCTest
@testable import Pecule

// Pins the planner's current behaviour before real bank amounts are fed into it.
final class BudgetPlannerCharacterizationTests: XCTestCase {
    private let march = TestFixtures.date(2026, 3, 14)

    private func makeService() -> BudgetPlannerService {
        BudgetPlannerService(calendar: TestFixtures.utcCalendar(), referenceDateProvider: { [march] in march })
    }

    private func subscription(_ name: String, _ amount: String, _ cycle: BillingCycle, category: ExpenseCategory, active: Bool = true) -> Subscription {
        Subscription(name: name, amount: TestFixtures.decimal(amount), billingCycle: cycle, category: category, nextBillingDate: TestFixtures.date(2026, 3, 20), isActive: active)
    }

    private func purchase(_ title: String, _ amount: String, on date: Date, category: String) -> Purchase {
        Purchase(title: title, amount: TestFixtures.decimal(amount), date: date, category: category, merchant: title, notes: nil)
    }

    func testIncomeCombinesRecurringComplementsAndOverrides() {
        let salary = IncomeSource(name: "Salaire", amount: 1500, type: .salary, startDate: TestFixtures.date(2025, 9, 1), isRecurring: true, isActive: true)
        let bonus = IncomeSource(name: "Prime", amount: 200, type: .bonus, startDate: TestFixtures.date(2026, 3, 5), isRecurring: false, isActive: true)
        let ended = IncomeSource(name: "Ancien", amount: 999, type: .other, startDate: TestFixtures.date(2025, 1, 1), endDate: TestFixtures.date(2025, 12, 31), isRecurring: true, isActive: true)
        let inactive = IncomeSource(name: "Inactif", amount: 999, type: .other, startDate: TestFixtures.date(2025, 1, 1), isRecurring: true, isActive: false)
        let replace = MonthlyIncomeOverride(incomeSourceID: salary.id, monthStartDate: TestFixtures.date(2026, 3, 1), amount: 1600, replacesSourceAmount: true)
        let add = MonthlyIncomeOverride(incomeSourceID: bonus.id, monthStartDate: TestFixtures.date(2026, 3, 1), amount: 50, replacesSourceAmount: false)

        let summary = makeService().summary(subscriptions: [], purchases: [], incomeSources: [salary, bonus, ended, inactive], monthlyIncomeOverrides: [replace, add])

        XCTAssertEqual(summary.recurringIncome, 1500)
        XCTAssertEqual(summary.incomeComplements, 200)
        XCTAssertEqual(summary.incomeOverrideDelta, 150, "+100 replaced salary, +50 added to the bonus")
        XCTAssertEqual(summary.totalEstimatedIncome, 1850)
    }

    func testExpensesAmortiseSubscriptionsAndBucketPurchasesByMonth() {
        let subscriptions = [
            subscription("Netflix", "15.99", .monthly, category: .subscriptions),
            subscription("Assurance", "120", .yearly, category: .insurance),
            subscription("Paused", "50", .monthly, category: .subscriptions, active: false),
        ]
        let purchases = [
            purchase("Courses", "42.10", on: TestFixtures.date(2026, 3, 2), category: ExpenseCategory.groceries.storageValue),
            purchase("Restau", "30", on: TestFixtures.date(2026, 3, 31, hour: 23), category: "Leisure"),
            purchase("Février", "99", on: TestFixtures.date(2026, 2, 28), category: ExpenseCategory.groceries.storageValue),
            purchase("Mystère", "5", on: TestFixtures.date(2026, 3, 10), category: "Unknown label"),
        ]

        let summary = makeService().summary(subscriptions: subscriptions, purchases: purchases)

        XCTAssertEqual(summary.fixedCharges, TestFixtures.decimal("25.99"), "15.99 + 120/12")
        XCTAssertEqual(summary.variableExpenses, TestFixtures.decimal("77.10"), "only March purchases")
        XCTAssertEqual(summary.totalExpenses, TestFixtures.decimal("103.09"))
        XCTAssertEqual(summary.spendingByCategory["Unknown label"], 5, "unknown labels remain distinct")
        XCTAssertEqual(summary.spendingByCategory["Groceries"], TestFixtures.decimal("42.10"))
        XCTAssertEqual(summary.spendingByCategory["Insurance"], 10)
        XCTAssertEqual(summary.categorySummaries.first?.category, "Groceries", "sorted by total spent descending")
    }

    @MainActor
    func testBankAmountsReplacePlannedOnesOnlyWhereALinkExists() {
        let accountID = UUID()
        let otherAccountID = UUID()
        let netflix = subscription("Netflix", "15.99", .monthly, category: .subscriptions)
        let insurance = subscription("Assurance", "120", .yearly, category: .insurance)
        let spotify = subscription("Spotify", "10.99", .monthly, category: .subscriptions)
        let groceries = purchase("Courses", "40", on: TestFixtures.date(2026, 3, 2), category: ExpenseCategory.groceries.storageValue)
        let salary = IncomeSource(name: "Salaire", amount: 1500, type: .salary, startDate: TestFixtures.date(2025, 9, 1), isRecurring: true, isActive: true)

        func transaction(_ ref: String, _ amount: String, _ direction: BankTransactionDirection, day: Int, account: UUID = accountID, category: ExpenseCategory = .other, status: BankTransactionStatus = .booked, currency: String = "EUR", link: BankTransactionLink? = nil, internalTransfer: Bool = false) -> BankTransaction {
            let transaction = BankTransaction(externalID: "h#\(ref)", accountID: account, amount: TestFixtures.decimal(amount), direction: direction, currencyCode: currency, bookingDate: TestFixtures.date(2026, 3, day), label: ref, status: status, category: category.storageValue, isInternalTransfer: internalTransfer)
            transaction.apply(link)
            return transaction
        }
        let transactions = [
            transaction("netflix", "17.99", .debit, day: 3, link: .subscription(netflix.id)),
            transaction("insurance", "120", .debit, day: 4, link: .subscription(insurance.id)),
            transaction("courses", "38.50", .debit, day: 2, link: .purchase(groceries.id)),
            transaction("fuel", "55", .debit, day: 6, category: .fuel),
            transaction("pending", "999", .debit, day: 7, category: .fuel, status: .pending),
            transaction("usd", "999", .debit, day: 7, category: .fuel, currency: "USD"),
            transaction("card-mirror", "999", .debit, day: 7, account: otherAccountID, category: .fuel),
            transaction("transfer", "500", .debit, day: 8, internalTransfer: true),
            transaction("salary", "1487.20", .credit, day: 1, link: .income(salary.id)),
            transaction("refund", "12", .credit, day: 9),
            transaction("april", "999", .debit, day: 31, category: .fuel),
        ]
        transactions[10].bookingDate = TestFixtures.date(2026, 4, 1)

        let service = makeService()
        let summary = service.summary(
            subscriptions: [netflix, insurance, spotify],
            purchases: [groceries],
            incomeSources: [salary],
            bankTransactions: transactions,
            includedAccountIDs: [accountID]
        )

        XCTAssertEqual(summary.dataSource, .bank)
        XCTAssertEqual(summary.fixedCharges, TestFixtures.decimal("38.98"), "17.99 real Netflix + 120/12 amortised insurance + 10.99 planned Spotify")
        XCTAssertEqual(summary.variableExpenses, TestFixtures.decimal("81.50"), "38.50 real purchase + 55 fuel - 12 received refund; excluded transactions stay excluded")
        XCTAssertEqual(summary.spendingByCategory["Fuel"], 55)
        XCTAssertEqual(summary.recurringIncome, 1500)
        XCTAssertEqual(summary.incomeOverrideDelta, TestFixtures.decimal("-12.80"), "the settled salary is the real amount")
        XCTAssertEqual(summary.totalEstimatedIncome, TestFixtures.decimal("1487.20"))
        XCTAssertEqual(summary.unmatchedIncome, 0, "a received refund reduces expenses, never income")

        let planned = service.summary(subscriptions: [netflix, insurance, spotify], purchases: [groceries], incomeSources: [salary], bankTransactions: transactions, includedAccountIDs: [accountID], prefersBankAmounts: false)
        XCTAssertEqual(planned.dataSource, .planned)
        XCTAssertEqual(planned.fixedCharges, TestFixtures.decimal("36.98"))
        XCTAssertEqual(planned.variableExpenses, 40)
        XCTAssertEqual(planned.totalEstimatedIncome, 1500)
        XCTAssertEqual(planned.unmatchedIncome, 0)

        let noAccounts = service.summary(subscriptions: [netflix, insurance, spotify], purchases: [groceries], incomeSources: [salary], bankTransactions: transactions)
        XCTAssertEqual(noAccounts, planned, "without an included account the planner behaves exactly as before")
    }

    func testBudgetStatusesUseOverridesThenRulesAndSkipEmptyCategories() {
        let rules = [BudgetRule(category: ExpenseCategory.groceries.storageValue, monthlyAmount: 300), BudgetRule(category: ExpenseCategory.fuel.storageValue, monthlyAmount: 80)]
        let overrides = [BudgetOverride(category: ExpenseCategory.groceries.storageValue, year: 2026, month: 3, monthlyAmount: 250)]
        let purchases = [purchase("Courses", "260", on: TestFixtures.date(2026, 3, 2), category: ExpenseCategory.groceries.storageValue)]

        let summary = makeService().summary(subscriptions: [], purchases: purchases, budgetRules: rules, budgetOverrides: overrides)

        let groceries = summary.budgetStatuses.first { $0.category == "Groceries" }
        XCTAssertEqual(groceries?.plannedAmount, 250, "the month override wins over the rule")
        XCTAssertEqual(groceries?.spentAmount, 260)
        XCTAssertEqual(groceries?.isOverspent, true)
        XCTAssertEqual(summary.budgetStatuses.first { $0.category == "Fuel" }?.plannedAmount, 80)
        XCTAssertNil(summary.budgetStatuses.first { $0.category == "Health" }, "no plan and no spending: omitted")
        XCTAssertEqual(summary.budgetStatuses.map(\.category), ["Fuel", "Groceries"], "alphabetical")
        XCTAssertEqual(summary.remainingToLive, TestFixtures.decimal("-260"))
        XCTAssertEqual(summary.potentialSavings, 0)
    }
}
