import Foundation
import SwiftData

// Frozen snapshot of the pre-planning store. Never modify these shapes.
extension PeculeSchemaV5 {

// Copies figées des formes persistées. Un type courant partagé ici ferait dépendre le disque
// d'aujourd'hui d'un renommage de demain : la migration lirait une valeur que plus rien ne décode.
enum BillingCycle: String, Codable, Hashable {
    case monthly
    case yearly
}

enum HabitFrequency: String, Codable, Hashable {
    case daily
    case weekly
}

enum IncomeType: String, Codable, Hashable {
    case salary
    case aid
    case bonus
    case mobility
    case other
}

enum BankInstitution: String, Codable, Hashable {
    case mock
    case boursorama
    case revolut
    case manual
}

enum ExternalAccountStatus: String, Codable, Hashable {
    case active
    case needsReconnect
    case error
}

enum BankTransactionDirection: String, Codable, Hashable {
    case debit
    case credit
}

enum BankTransactionStatus: String, Codable, Hashable {
    case booked
    case pending
}

// Mêmes calculs que les aides courantes, recopiés pour que leur évolution ne réécrive pas
// le comportement d'une version passée.
enum Frozen {
    static func monthStart(for date: Date, in calendar: Calendar) -> Date {
        var monthCalendar = calendar
        monthCalendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        let components = monthCalendar.dateComponents([.year, .month], from: date)
        return monthCalendar.date(
            from: DateComponents(
                timeZone: monthCalendar.timeZone,
                year: components.year,
                month: components.month,
                day: 1,
                hour: 12
            )
        ) ?? monthCalendar.startOfDay(for: date)
    }

    static func currencyRounded(_ value: Decimal) -> Decimal {
        var input = value
        var result = Decimal()
        NSDecimalRound(&result, &input, 2, .bankers)
        return result
    }
}
@Model
final class Subscription: Identifiable {
    var id: UUID
    var name: String
    var amount: Decimal
    var billingCycle: BillingCycle
    var category: String
    var nextBillingDate: Date
    var isActive: Bool

    init(
        id: UUID = UUID(),
        name: String,
        amount: Decimal,
        billingCycle: BillingCycle,
        category: String,
        nextBillingDate: Date,
        isActive: Bool
    ) {
        self.id = id
        self.name = name
        self.amount = amount
        self.billingCycle = billingCycle
        self.category = category
        self.nextBillingDate = nextBillingDate
        self.isActive = isActive
    }
}

@Model
final class Purchase: Identifiable {
    var id: UUID
    var title: String
    var amount: Decimal
    var date: Date
    var category: String
    var merchant: String
    var notes: String?

    init(
        id: UUID = UUID(),
        title: String,
        amount: Decimal,
        date: Date,
        category: String,
        merchant: String,
        notes: String?
    ) {
        self.id = id
        self.title = title
        self.amount = amount
        self.date = date
        self.category = category
        self.merchant = merchant
        self.notes = notes
    }
}

@Model
final class Goal: Identifiable {
    var id: UUID
    var title: String
    var targetAmount: Decimal
    var currentAmount: Decimal
    var targetDate: Date
    var category: String
    var intention: String = "deadline"
    var durationMonths: Int?
    var startedAt: Date?
    var showsFundingHelp: Bool = false
    var isArchived: Bool

    init(
        id: UUID = UUID(),
        title: String,
        targetAmount: Decimal,
        currentAmount: Decimal,
        targetDate: Date,
        category: String,
        isArchived: Bool
    ) {
        self.id = id
        self.title = title
        self.targetAmount = targetAmount
        self.currentAmount = currentAmount
        self.targetDate = targetDate
        self.category = category
        self.isArchived = isArchived
    }

    var progress: Double {
        let targetValue = NSDecimalNumber(decimal: targetAmount).doubleValue

        guard targetValue > 0 else {
            return 0
        }

        let currentValue = NSDecimalNumber(decimal: currentAmount).doubleValue

        return min(max(currentValue / targetValue, 0), 1)
    }
}

@Model
final class Habit: Identifiable {
    var id: UUID
    var title: String
    var frequency: HabitFrequency
    var targetCount: Int
    var completedCount: Int
    var linkedGoalID: UUID?
    var isActive: Bool

    init(
        id: UUID = UUID(),
        title: String,
        frequency: HabitFrequency,
        targetCount: Int,
        completedCount: Int,
        linkedGoalID: UUID?,
        isActive: Bool
    ) {
        self.id = id
        self.title = title
        self.frequency = frequency
        self.targetCount = targetCount
        self.completedCount = completedCount
        self.linkedGoalID = linkedGoalID
        self.isActive = isActive
    }

    var progress: Double {
        guard targetCount > 0 else {
            return 0
        }

        let ratio = Double(completedCount) / Double(targetCount)
        return min(max(ratio, 0), 1)
    }
}

@Model
final class IncomeSource: Identifiable {
    var id: UUID
    var name: String
    var amount: Decimal
    var type: IncomeType
    var startDate: Date
    var endDate: Date?
    var isRecurring: Bool
    var isActive: Bool

    init(
        id: UUID = UUID(),
        name: String,
        amount: Decimal,
        type: IncomeType,
        startDate: Date,
        endDate: Date? = nil,
        isRecurring: Bool,
        isActive: Bool
    ) {
        self.id = id
        self.name = name
        self.amount = amount
        self.type = type
        self.startDate = startDate
        self.endDate = endDate
        self.isRecurring = isRecurring
        self.isActive = isActive
    }

    func applies(toMonthContaining date: Date, calendar: Calendar = .current) -> Bool {
        guard isActive else {
            return false
        }

        let targetMonth = Frozen.monthStart(for: date, in: calendar)
        let startMonth = Frozen.monthStart(for: startDate, in: calendar)

        guard targetMonth >= startMonth else {
            return false
        }

        if !isRecurring {
            return calendar.isDate(targetMonth, equalTo: startMonth, toGranularity: .month)
        }

        guard let endDate else {
            return true
        }

        let endMonth = max(Frozen.monthStart(for: endDate, in: calendar), startMonth)
        return targetMonth <= endMonth
    }
}

@Model
final class MonthlyIncomeOverride: Identifiable {
    var id: UUID
    var incomeSourceID: UUID
    var monthStartDate: Date
    var amount: Decimal
    var replacesSourceAmount: Bool

    init(
        id: UUID = UUID(),
        incomeSourceID: UUID,
        monthStartDate: Date,
        amount: Decimal,
        replacesSourceAmount: Bool
    ) {
        self.id = id
        self.incomeSourceID = incomeSourceID
        self.monthStartDate = monthStartDate
        self.amount = amount
        self.replacesSourceAmount = replacesSourceAmount
    }

    func applies(toMonthContaining date: Date, calendar: Calendar = .current) -> Bool {
        Frozen.monthStart(for: monthStartDate, in: calendar) == Frozen.monthStart(for: date, in: calendar)
    }

    func resolvedAmount(for baseAmount: Decimal) -> Decimal {
        let value = replacesSourceAmount ? amount : (baseAmount + amount)
        return Frozen.currencyRounded(value)
    }
}

@Model
final class BudgetRule: Identifiable {
    var id: UUID
    var category: String
    var monthlyAmount: Decimal

    init(
        id: UUID = UUID(),
        category: String,
        monthlyAmount: Decimal
    ) {
        self.id = id
        self.category = category
        self.monthlyAmount = monthlyAmount
    }
}

@Model
final class BudgetOverride: Identifiable {
    var id: UUID
    var category: String
    var year: Int
    var month: Int
    var monthlyAmount: Decimal

    init(
        id: UUID = UUID(),
        category: String,
        year: Int,
        month: Int,
        monthlyAmount: Decimal
    ) {
        self.id = id
        self.category = category
        self.year = year
        self.month = month
        self.monthlyAmount = monthlyAmount
    }

    func matches(year: Int, month: Int) -> Bool {
        self.year == year && self.month == month
    }
}

@Model
final class ExternalAccount: Identifiable {
    var id: UUID
    // identification_hash from Enable Banking: stable across re-authorizations, unlike the per-session uid.
    @Attribute(.unique) var stableIdentifier: String
    var currentUID: String
    var linkID: String
    var institution: String
    var name: String
    var maskedIBAN: String?
    var currencyCode: String
    var balance: Decimal?
    var balanceType: String?
    var balanceDate: Date?
    var consentValidUntil: Date?
    var status: String
    var lastSyncedAt: Date?
    var lastSyncError: String?
    var requiresInclusionReview: Bool = false
    var isIncludedInTotals: Bool

    init(
        id: UUID = UUID(),
        stableIdentifier: String,
        currentUID: String,
        linkID: String,
        institution: BankInstitution,
        name: String,
        maskedIBAN: String? = nil,
        currencyCode: String,
        balance: Decimal? = nil,
        balanceType: String? = nil,
        balanceDate: Date? = nil,
        consentValidUntil: Date? = nil,
        status: ExternalAccountStatus = .active,
        lastSyncedAt: Date? = nil,
        lastSyncError: String? = nil,
        isIncludedInTotals: Bool = true
    ) {
        self.id = id
        self.stableIdentifier = stableIdentifier
        self.currentUID = currentUID
        self.linkID = linkID
        self.institution = institution.rawValue
        self.name = name
        self.maskedIBAN = maskedIBAN
        self.currencyCode = currencyCode
        self.balance = balance
        self.balanceType = balanceType
        self.balanceDate = balanceDate
        self.consentValidUntil = consentValidUntil
        self.status = status.rawValue
        self.lastSyncedAt = lastSyncedAt
        self.lastSyncError = lastSyncError
        self.isIncludedInTotals = isIncludedInTotals
    }
}

@Model
final class BankTransaction: Identifiable {
    var id: UUID
    @Attribute(.unique) var externalID: String
    var accountID: UUID
    // Always positive; the sign lives in `direction`, like every other amount in the app.
    var amount: Decimal
    var direction: String
    var currencyCode: String
    var bookingDate: Date
    var valueDate: Date?
    var label: String
    var counterpartyName: String?
    var status: String
    var merchantCategoryCode: String?
    var bankTransactionCode: String?
    var category: String
    var isInternalTransfer: Bool
    var isIgnored: Bool
    var linkedPurchaseID: UUID?
    var linkedSubscriptionID: UUID?
    var linkedIncomeSourceID: UUID?
    // Additive V3 annotations. Automatic preserves the original bank evidence.
    var natureOverride: String = "automatic"
    var refundOfTransactionID: UUID?
    var userNote: String?
    var automaticCategory: String?
    var categoryOverride: String?
    var isAbsentFromBank: Bool = false
    var internalTransferOverride: Bool?
    var transferEvidence: String?
    var installmentDecision: String?
    var installmentNumber: Int?
    var installmentCount: Int?


    init(
        id: UUID = UUID(),
        externalID: String,
        accountID: UUID,
        amount: Decimal,
        direction: BankTransactionDirection,
        currencyCode: String,
        bookingDate: Date,
        valueDate: Date? = nil,
        label: String,
        counterpartyName: String? = nil,
        status: BankTransactionStatus = .booked,
        merchantCategoryCode: String? = nil,
        bankTransactionCode: String? = nil,
        category: String = "Other",
        isInternalTransfer: Bool = false,
        isIgnored: Bool = false,
        linkedPurchaseID: UUID? = nil,
        linkedSubscriptionID: UUID? = nil,
        linkedIncomeSourceID: UUID? = nil
    ) {
        self.id = id
        self.externalID = externalID
        self.accountID = accountID
        self.amount = amount
        self.direction = direction.rawValue
        self.currencyCode = currencyCode
        self.bookingDate = bookingDate
        self.valueDate = valueDate
        self.label = label
        self.counterpartyName = counterpartyName
        self.status = status.rawValue
        self.merchantCategoryCode = merchantCategoryCode
        self.bankTransactionCode = bankTransactionCode
        self.category = category
        self.isInternalTransfer = isInternalTransfer
        self.isIgnored = isIgnored
        self.linkedPurchaseID = linkedPurchaseID
        self.linkedSubscriptionID = linkedSubscriptionID
        self.linkedIncomeSourceID = linkedIncomeSourceID
    }
}

@Model
final class BankImportCheckpoint {
    @Attribute(.unique) var accountID: UUID
    var windowStart: Date?
    var continuationKey: String?
    var fetchedExternalIDs: [String] = []
    var initialImportCompleted: Bool = false
    var lastCompletedAt: Date?
    var lastAttemptAt: Date?
    var lastFailedAt: Date?
    var requestedHistoryStart: Date?

    init(accountID: UUID) { self.accountID = accountID }
}

@Model
final class BankPendingAuthorization {
    @Attribute(.unique) var key: String = "pending"
    var linkID: String
    var institution: String
    var requiresAccountSelection: Bool = false
    var expiresAt: Date

    init(linkID: String, institution: BankInstitution, expiresAt: Date) {
        self.linkID = linkID
        self.institution = institution.rawValue
        self.expiresAt = expiresAt
    }
}

@Model
final class CategoryRecord {
    @Attribute(.unique) var key: String
    var name: String
    init(key: String, name: String) { self.key = key; self.name = name }
}
@Model
final class GoalContribution {
    @Attribute(.unique) var id: UUID
    var goalID: UUID
    var date: Date
    var amount: Decimal
    init(id: UUID = UUID(), goalID: UUID, date: Date, amount: Decimal) {
        self.id = id; self.goalID = goalID; self.date = date; self.amount = Frozen.currencyRounded(amount)
    }
}
@Model
final class MonthlySpendingLimit {
    @Attribute(.unique) var periodKey: String
    var amount: Decimal
    init(periodKey: String, amount: Decimal) {
        self.periodKey = periodKey; self.amount = Frozen.currencyRounded(amount)
    }
}
}
