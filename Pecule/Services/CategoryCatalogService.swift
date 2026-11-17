import Foundation
import SwiftData

extension PeculeDataStore {
    func categoryCatalog(preserving snapshot: AppDataSnapshot) throws -> [ExpenseCategory] {
        let names = snapshot.purchases.map(\.category) + snapshot.subscriptions.map(\.category) + snapshot.goals.map(\.category) + snapshot.budgetRules.map(\.category) + snapshot.budgetOverrides.map(\.category) + snapshot.bankTransactions.map(\.category)
        var records = try container.mainContext.fetch(FetchDescriptor<CategoryRecord>())
        var known = Set(records.map(\.key))
        for name in Set(names) where !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && ExpenseCategory(matching: name) == nil {
            let record = CategoryRecord(name: name)
            if known.insert(record.key).inserted { container.mainContext.insert(record); records.append(record) }
        }
        if container.mainContext.hasChanges { try container.mainContext.save() }
        return ExpenseCategory.allCases + records.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map { ExpenseCategory.canonicalCategory(for: $0.name) }
    }

    func createCategory(name: String) throws -> ExpenseCategory {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 60 else { throw BankTransactionEditError.unavailable }
        let category = ExpenseCategory.canonicalCategory(for: trimmed)
        if ExpenseCategory(matching: trimmed) != nil { return category }
        let key = category.id
        let matches = try container.mainContext.fetch(FetchDescriptor<CategoryRecord>(predicate: #Predicate { $0.key == key }))
        if let existing = matches.first { return ExpenseCategory.canonicalCategory(for: existing.name) }
        container.mainContext.insert(CategoryRecord(name: trimmed))
        try container.mainContext.save()
        return category
    }
}
