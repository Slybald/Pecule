import Foundation
import Synchronization

struct InstallmentEvidence: Equatable {
    let number: Int
    let count: Int
}

struct InstallmentService {
    // Analyser un libellé est pur, et les libellés se répètent : un même commerçant revient des
    // dizaines de fois dans un historique. Sans cache, chaque lecture recompilait jusqu'à trois
    // expressions régulières par opération, sur des chemins de rendu. Le cache est borné pour
    // qu'un import de 50 000 opérations ne le laisse pas enfler sans fin.
    private static let cacheLimit = 4_096
    private static let cache = Mutex<[String: InstallmentEvidence?]>([:])

    static func evidence(label: String) -> InstallmentEvidence? {
        if let cached = cache.withLock({ $0[label] }) {
            return cached
        }
        let computed = computeEvidence(label: label)
        cache.withLock { storage in
            if storage.count >= cacheLimit {
                storage.removeAll(keepingCapacity: true)
            }
            storage[label] = computed
        }
        return computed
    }

    // Equal amounts alone are not enough. Only explicit n/N or "Nx" markers propose a plan.
    private static func computeEvidence(label: String) -> InstallmentEvidence? {
        let normalized = BankTransactionCategorizer.normalize(label)
        let original = label.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR")).uppercased()
        // Neither a booking date (12/12/2026) nor a card date (CARTE 11/12) is installment evidence:
        // the n/N form only counts when an explicit installment word sits right before it.
        if let range = original.range(of: #"(?<![\d/])([1-9][0-9]?)\s*/\s*([2-9]|[12][0-9]|3[0-6])\b(?!\s*/\s*\d)"#, options: .regularExpression) {
            let prefix = String(original[..<range.lowerBound].suffix(24))
            let hasMarker = prefix.range(
                of: #"(ECHEANCE|VERSEMENT|MENSUALITE|PAIEMENT|TRANCHE|FOIS)S?\s*(N\s*)?[^A-Z0-9]*$"#,
                options: .regularExpression
            ) != nil
            let parts = original[range].split(separator: "/").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if hasMarker, parts.count == 2, parts[0] <= parts[1] { return .init(number: parts[0], count: parts[1]) }
        }
        if let range = normalized.range(of: #"\b([2-9]|[12][0-9]|3[0-6])\s*(X|FOIS)\b"#, options: .regularExpression),
           let count = Int(normalized[range].prefix(while: \.isNumber)) {
            return .init(number: 1, count: count)
        }
        return nil
    }
}

extension BankTransaction {
    var installmentEvidence: InstallmentEvidence? {
        guard normalizedDirection == .debit else { return nil }
        if installmentDecision == "confirmed", let count = installmentCount, let number = installmentNumber {
            return .init(number: number, count: count)
        }
        return InstallmentService.evidence(label: label)
    }
    var excludesInfiniteRecurrence: Bool {
        installmentDecision != "rejected" && installmentEvidence != nil
    }
}

extension PeculeDataStore {
    func decideInstallment(id: UUID, decision: String, number: Int, count: Int) throws {
        guard ["confirmed", "rejected", "suggested"].contains(decision), (2...36).contains(count), (1...count).contains(number) else { throw BankTransactionEditError.unavailable }
        let transaction = try editableBankTransaction(id: id)
        guard transaction.normalizedDirection == .debit else { throw BankTransactionEditError.unavailable }
        transaction.installmentDecision = decision
        transaction.installmentNumber = number
        transaction.installmentCount = count
        try container.mainContext.save()
    }
}
