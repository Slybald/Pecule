import Foundation

enum CreditNature: String, CaseIterable {
    case salary, personalTransfer, internalTransfer, refund, otherIncome, needsReview
}

extension BankTransaction {
    // Recurrence is intentionally absent: it never proves payroll or ownership.
    var creditNature: CreditNature {
        if isInternalTransfer { return .internalTransfer }
        if natureOverride == "income" { return .otherIncome } // V3 compatibility
        if let manual = CreditNature(rawValue: natureOverride) { return manual }
        if isRefund { return .refund }
        let text = " " + BankTransactionCategorizer.normalize(label) + " "
        if hasSalaryBankCode || [" SALAIRE ", " SALARY ", " PAYROLL "].contains(where: text.contains) { return .salary }
        return .needsReview
    }

    // One reading of the bank code for both the verdict and its stated provenance: a mixed-case
    // "Salaires" must not classify as salary through one path and be reported as label evidence by the other.
    var hasSalaryBankCode: Bool {
        bankTransactionCode?.uppercased().contains("SALA") == true
    }

    var natureEvidence: ClassificationEvidence {
        if natureOverride != "automatic" || internalTransferOverride != nil { return .user }
        if isInternalTransfer { return transferEvidence.flatMap(ClassificationEvidence.init(rawValue:)) ?? .legacy }
        if creditNature == .salary { return hasSalaryBankCode ? .bankCode : .label }
        if isRefund { return .label }
        return .insufficient
    }

    var natureConfidence: ClassificationConfidence {
        ClassificationConfidence(evidence: natureEvidence)
    }

    var categoryEvidence: ClassificationEvidence {
        if categoryOverride != nil { return .user }
        if automaticCategory == nil { return .legacy }
        if category == ExpenseCategory.other.storageValue { return .insufficient }
        let mcc = BankTransactionCategorizer().category(label: "", counterparty: nil,
            merchantCategoryCode: merchantCategoryCode, bankTransactionCode: nil)
        return mcc == .other ? .label : .bankCode
    }

    // La catégorie ne connaît pas les provenances de virement : `knownAccount` et `pairedAccounts`
    // n'y apparaissent jamais, et l'échelle partagée les traite de toute façon comme il se doit.
    var categoryConfidence: ClassificationConfidence {
        ClassificationConfidence(evidence: categoryEvidence)
    }

    // Socle commun aux deux passes de rapprochement, celle des entrées manuelles et celle des
    // virements internes. Recopié à deux endroits, il suffisait d'en corriger un pour que les deux
    // passes divergent : une opération rapprochable d'un côté, invisible de l'autre.
    var isEligibleForReconciliation: Bool {
        !isAbsentFromBank && !isRefund && !isIgnored && normalizedStatus == .booked && currencyCode == "EUR"
    }

    var needsClassificationReview: Bool {
        guard !isInternalTransfer && !isIgnored else { return false }
        return normalizedDirection == .credit
            ? creditNature == .needsReview ||
                (creditNature == .refund && refundOfTransactionID == nil && categoryEvidence == .insufficient)
            : categoryConfidence == .low
    }
}
