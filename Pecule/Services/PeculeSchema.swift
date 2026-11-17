import Foundation
import SwiftData

// V1 mirrors the schema the store was created with before versioning existed; it must never change.
enum PeculeSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            Subscription.self,
            Purchase.self,
            Goal.self,
            Habit.self,
            IncomeSource.self,
            MonthlyIncomeOverride.self,
            BudgetRule.self,
            BudgetOverride.self,
        ]
    }
}

enum PeculeSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    // Non qualifiés, ces noms désignent les copies figées déclarées dans `extension PeculeSchemaV2`,
    // et non les modèles courants : la résolution part du type englobant.
    static var models: [any PersistentModel.Type] {
        PeculeSchemaV1.models + [ExternalAccount.self, BankTransaction.self]
    }
}

enum PeculeSchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [Subscription.self, Purchase.self, Goal.self, Habit.self, IncomeSource.self,
         MonthlyIncomeOverride.self, BudgetRule.self, BudgetOverride.self,
         ExternalAccount.self, BankTransaction.self, BankImportCheckpoint.self, BankPendingAuthorization.self]
    }
}

enum PeculeSchemaV4: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(4, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [Subscription.self, Purchase.self, Goal.self, Habit.self, IncomeSource.self,
         MonthlyIncomeOverride.self, BudgetRule.self, BudgetOverride.self,
         ExternalAccount.self, BankTransaction.self, BankImportCheckpoint.self, BankPendingAuthorization.self, CategoryRecord.self, GoalContribution.self]
    }
}

enum PeculeSchemaV5: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(5, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [Subscription.self, Purchase.self, Goal.self, Habit.self, IncomeSource.self,
         MonthlyIncomeOverride.self, BudgetRule.self, BudgetOverride.self,
         ExternalAccount.self, BankTransaction.self, BankImportCheckpoint.self, BankPendingAuthorization.self, CategoryRecord.self, GoalContribution.self, MonthlySpendingLimit.self]
    }
}

enum PeculeSchemaV6: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(6, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [Subscription.self, Purchase.self, Goal.self, Habit.self, IncomeSource.self,
         MonthlyIncomeOverride.self, BudgetRule.self, BudgetOverride.self, ExternalAccount.self,
         BankTransaction.self, BankImportCheckpoint.self, BankPendingAuthorization.self,
         CategoryRecord.self, GoalContribution.self, MonthlySpendingLimit.self,
         PlannedCommitment.self, CommitmentPayment.self, PlanningAccountSetting.self,
         PurchaseScenario.self, GoalProvision.self, ProvisionPayment.self,
         GoalAllocationPlan.self, GoalAllocation.self, ExpectedRefund.self, RefundReceipt.self,
         TransactionRule.self, RuleApplication.self, TransactionSplit.self]
    }
}

enum PeculeMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [PeculeSchemaV1.self, PeculeSchemaV2.self, PeculeSchemaV3.self, PeculeSchemaV4.self, PeculeSchemaV5.self, PeculeSchemaV6.self]
    }

    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: PeculeSchemaV1.self, toVersion: PeculeSchemaV2.self),
         .lightweight(fromVersion: PeculeSchemaV2.self, toVersion: PeculeSchemaV3.self),
         .lightweight(fromVersion: PeculeSchemaV3.self, toVersion: PeculeSchemaV4.self),
         .lightweight(fromVersion: PeculeSchemaV4.self, toVersion: PeculeSchemaV5.self),
         .lightweight(fromVersion: PeculeSchemaV5.self, toVersion: PeculeSchemaV6.self)]
    }
}

enum PeculeSchema {
    static var current: Schema {
        Schema(versionedSchema: PeculeSchemaV6.self)
    }
}
