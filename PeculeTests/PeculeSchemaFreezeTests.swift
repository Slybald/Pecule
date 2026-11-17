import Foundation
import SwiftData
import XCTest
@testable import Pecule

// Épingle la forme stockée du schéma courant (V6). Une propriété ajoutée, retirée, renommée ou retypée sur
// un modèle vivant change ce que SwiftData écrit sur le disque : sans nouvelle version de schéma ni étape de
// migration, une base déjà installée s'ouvre mal. Ce test échoue alors, et son message donne la forme réelle.
//
// Changement de schéma voulu : créer V7 (figer V6 dans HistoricalSchemaV6.swift, l'ajouter à
// tools/automation/check_frozen_schemas.sh), puis mettre `pinnedV6` à jour et le renommer pour V7.
final class PeculeSchemaFreezeTests: XCTestCase {
    private static let pinnedV6: [String] = [
        "BankImportCheckpoint: accountID:UUID#, continuationKey:Optional<String>, fetchedExternalIDs:Array<String>, initialImportCompleted:Bool, lastAttemptAt:Optional<Date>, lastCompletedAt:Optional<Date>, lastFailedAt:Optional<Date>, requestedHistoryStart:Optional<Date>, windowStart:Optional<Date>",
        "BankPendingAuthorization: expiresAt:Date, institution:String, key:String#, linkID:String, requiresAccountSelection:Bool",
        "BankTransaction: accountID:UUID, amount:NSDecimal, automaticCategory:Optional<String>, bankTransactionCode:Optional<String>, bookingDate:Date, category:String, categoryOverride:Optional<String>, counterpartyName:Optional<String>, currencyCode:String, direction:String, externalID:String#, id:UUID, installmentCount:Optional<Int>, installmentDecision:Optional<String>, installmentNumber:Optional<Int>, internalTransferOverride:Optional<Bool>, isAbsentFromBank:Bool, isIgnored:Bool, isInternalTransfer:Bool, label:String, linkedIncomeSourceID:Optional<UUID>, linkedPurchaseID:Optional<UUID>, linkedSubscriptionID:Optional<UUID>, merchantCategoryCode:Optional<String>, natureOverride:String, refundOfTransactionID:Optional<UUID>, ruleApplicationID:Optional<UUID>, ruleCategory:Optional<String>, status:String, transferEvidence:Optional<String>, userNote:Optional<String>, valueDate:Optional<Date>",
        "BudgetOverride: category:String, id:UUID, month:Int, monthlyAmount:NSDecimal, year:Int",
        "BudgetRule: category:String, id:UUID, monthlyAmount:NSDecimal",
        "CategoryRecord: key:String#, name:String",
        "CommitmentPayment: amount:NSDecimal, commitmentID:UUID, occurrenceKey:String, transactionID:UUID#",
        "ExpectedRefund: amount:NSDecimal, dueDate:Optional<Date>, id:UUID#, isAbandoned:Bool, party:String, transactionID:UUID",
        "ExternalAccount: balance:Optional<NSDecimal>, balanceDate:Optional<Date>, balanceType:Optional<String>, consentValidUntil:Optional<Date>, currencyCode:String, currentUID:String, id:UUID, institution:String, isIncludedInTotals:Bool, lastSyncError:Optional<String>, lastSyncedAt:Optional<Date>, linkID:String, maskedIBAN:Optional<String>, name:String, requiresInclusionReview:Bool, stableIdentifier:String#, status:String",
        "Goal: category:String, currentAmount:NSDecimal, durationMonths:Optional<Int>, id:UUID, intention:String, isArchived:Bool, showsFundingHelp:Bool, startedAt:Optional<Date>, targetAmount:NSDecimal, targetDate:Date, title:String",
        "GoalAllocation: amount:NSDecimal, goalID:UUID#, priority:Int",
        "GoalAllocationPlan: capacity:NSDecimal, key:String#",
        "GoalContribution: amount:NSDecimal, date:Date, goalID:UUID, id:UUID#",
        "GoalProvision: dueDate:Date, goalID:UUID#, renewal:String",
        "Habit: completedCount:Int, frequency:HabitFrequency, id:UUID, isActive:Bool, linkedGoalID:Optional<UUID>, targetCount:Int, title:String",
        "IncomeSource: amount:NSDecimal, endDate:Optional<Date>, id:UUID, isActive:Bool, isRecurring:Bool, name:String, startDate:Date, type:IncomeType",
        "MonthlyIncomeOverride: amount:NSDecimal, id:UUID, incomeSourceID:UUID, monthStartDate:Date, replacesSourceAmount:Bool",
        "MonthlySpendingLimit: amount:NSDecimal, periodKey:String#",
        "PlannedCommitment: accountID:Optional<UUID>, amount:NSDecimal, cadence:String, category:String, count:Optional<Int>, direction:String, dueDate:Optional<Date>, id:UUID#, sourceID:Optional<UUID>, sourceKey:String#, sourceKind:String, status:String, title:String",
        "PlanningAccountSetting: accountID:UUID#, threshold:NSDecimal",
        "ProvisionPayment: amount:NSDecimal, contributionID:UUID, goalID:UUID, transactionID:UUID#",
        "Purchase: amount:NSDecimal, category:String, date:Date, id:UUID, merchant:String, notes:Optional<String>, title:String",
        "PurchaseScenario: accountID:Optional<UUID>, amount:NSDecimal, date:Date, id:UUID#, title:String",
        "RefundReceipt: amount:NSDecimal, refundID:UUID, transactionID:UUID#",
        "RuleApplication: appliedCategory:String, batchID:UUID, date:Date, id:UUID#, isUndone:Bool, previousCategory:String, ruleID:UUID, transactionID:UUID",
        "Subscription: amount:NSDecimal, billingCycle:BillingCycle, category:String, id:UUID, isActive:Bool, name:String, nextBillingDate:Date",
        "TransactionRule: accountID:Optional<UUID>, category:String, id:UUID#, isEnabled:Bool, merchant:String, priority:Int, text:String, title:String",
        "TransactionSplit: amount:NSDecimal, category:String, id:UUID#, transactionID:UUID",
    ]

    func testCurrentSchemaIsVersionSixAndItsStoredShapeIsPinned() {
        XCTAssertEqual(PeculeSchemaV6.versionIdentifier, Schema.Version(6, 0, 0))
        XCTAssertTrue(PeculeSchema.current.version == PeculeSchemaV6.versionIdentifier,
                      "le schéma courant a changé : figer V6 dans un HistoricalSchemaV6.swift et épingler la nouvelle forme")
        let actual = Self.shape(of: PeculeSchema.current)
        XCTAssertEqual(actual, Self.pinnedV6,
                       "La forme stockée du schéma courant a changé sans nouvelle version. Forme réelle :\n" + actual.map { "        \"\($0)\"," }.joined(separator: "\n"))
    }

    // Une ligne par entité : nom, puis propriétés triées « nom:type » ; « # » marque un attribut unique,
    // « -> » une relation (destination).
    static func shape(of schema: Schema) -> [String] {
        schema.entities.map { entity in
            var parts = entity.attributes.map { attribute in
                "\(attribute.name):\(attribute.valueType)" + (attribute.options.contains(where: { "\($0)".contains("unique") }) ? "#" : "")
            }
            parts += entity.relationships.map { "\($0.name)->\($0.destination)" }
            return "\(entity.name): " + parts.sorted().joined(separator: ", ")
        }.sorted()
    }
}
