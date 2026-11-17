import Foundation
import SwiftData

@Model final class PlannedCommitment {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var sourceKey: String
    var title: String
    var amount: Decimal
    var direction: String
    var dueDate: Date?
    var accountID: UUID?
    var cadence: String
    var count: Int?
    var status: String
    var category: String
    var sourceKind: String
    var sourceID: UUID?
    init(id: UUID = UUID(), sourceKey: String = UUID().uuidString, title: String, amount: Decimal,
         direction: String = "debit", dueDate: Date? = nil, accountID: UUID? = nil,
         cadence: String = "monthly", count: Int? = nil, status: String = "confirmed",
         category: String = "other", sourceKind: String = "manual", sourceID: UUID? = nil) {
        self.id = id; self.sourceKey = sourceKey; self.title = title; self.amount = amount.currencyRounded
        self.direction = direction; self.dueDate = dueDate; self.accountID = accountID
        self.cadence = cadence; self.count = count; self.status = status; self.category = category
        self.sourceKind = sourceKind; self.sourceID = sourceID
    }
}

@Model final class CommitmentPayment {
    @Attribute(.unique) var transactionID: UUID
    var commitmentID: UUID
    var occurrenceKey: String
    var amount: Decimal
    init(transactionID: UUID, commitmentID: UUID, occurrenceKey: String, amount: Decimal) {
        self.transactionID = transactionID; self.commitmentID = commitmentID
        self.occurrenceKey = occurrenceKey; self.amount = amount.currencyRounded
    }
}

@Model final class PlanningAccountSetting {
    @Attribute(.unique) var accountID: UUID
    var threshold: Decimal
    init(accountID: UUID, threshold: Decimal) { self.accountID = accountID; self.threshold = threshold.currencyRounded }
}

@Model final class PurchaseScenario {
    @Attribute(.unique) var id: UUID
    var title: String
    var amount: Decimal
    var date: Date
    var accountID: UUID?
    init(id: UUID = UUID(), title: String, amount: Decimal, date: Date, accountID: UUID?) {
        self.id = id; self.title = title; self.amount = amount.currencyRounded; self.date = date; self.accountID = accountID
    }
}

@Model final class GoalProvision {
    @Attribute(.unique) var goalID: UUID
    var dueDate: Date
    var renewal: String
    init(goalID: UUID, dueDate: Date, renewal: String = "none") {
        self.goalID = goalID; self.dueDate = dueDate; self.renewal = renewal
    }
}

@Model final class ProvisionPayment {
    @Attribute(.unique) var transactionID: UUID
    var goalID: UUID
    var amount: Decimal
    var contributionID: UUID
    init(transactionID: UUID, goalID: UUID, amount: Decimal, contributionID: UUID) {
        self.transactionID = transactionID; self.goalID = goalID; self.amount = amount; self.contributionID = contributionID
    }
}

@Model final class GoalAllocationPlan {
    @Attribute(.unique) var key: String = "shared"
    var capacity: Decimal
    init(capacity: Decimal) { self.capacity = capacity.currencyRounded }
}

@Model final class GoalAllocation {
    @Attribute(.unique) var goalID: UUID
    var amount: Decimal
    var priority: Int
    init(goalID: UUID, amount: Decimal, priority: Int) {
        self.goalID = goalID; self.amount = amount.currencyRounded; self.priority = priority
    }
}

@Model final class ExpectedRefund {
    @Attribute(.unique) var id: UUID
    var transactionID: UUID
    var amount: Decimal
    var party: String
    var dueDate: Date?
    var isAbandoned: Bool = false
    init(id: UUID = UUID(), transactionID: UUID, amount: Decimal, party: String, dueDate: Date?) {
        self.id = id; self.transactionID = transactionID; self.amount = amount.currencyRounded
        self.party = party; self.dueDate = dueDate
    }
}

@Model final class RefundReceipt {
    @Attribute(.unique) var transactionID: UUID
    var refundID: UUID
    var amount: Decimal
    init(transactionID: UUID, refundID: UUID, amount: Decimal) {
        self.transactionID = transactionID; self.refundID = refundID; self.amount = amount.currencyRounded
    }
}

@Model final class TransactionRule {
    @Attribute(.unique) var id: UUID
    var title: String
    var accountID: UUID?
    var merchant: String
    var text: String
    var category: String
    var priority: Int
    var isEnabled: Bool = true
    init(id: UUID = UUID(), title: String, accountID: UUID?, merchant: String, text: String, category: String, priority: Int) {
        self.id = id; self.title = title; self.accountID = accountID; self.merchant = merchant
        self.text = text; self.category = category; self.priority = priority
    }
}

@Model final class RuleApplication {
    @Attribute(.unique) var id: UUID
    var batchID: UUID
    var transactionID: UUID
    var ruleID: UUID
    var previousCategory: String
    var appliedCategory: String
    var date: Date
    var isUndone: Bool = false
    init(id: UUID = UUID(), batchID: UUID, transactionID: UUID, ruleID: UUID, previousCategory: String, appliedCategory: String, date: Date) {
        self.id = id; self.batchID = batchID; self.transactionID = transactionID; self.ruleID = ruleID
        self.previousCategory = previousCategory; self.appliedCategory = appliedCategory; self.date = date
    }
}

@Model final class TransactionSplit {
    @Attribute(.unique) var id: UUID
    var transactionID: UUID
    var category: String
    var amount: Decimal
    init(id: UUID = UUID(), transactionID: UUID, category: String, amount: Decimal) {
        self.id = id; self.transactionID = transactionID; self.category = category; self.amount = amount.currencyRounded
    }
}
