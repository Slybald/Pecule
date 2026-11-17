import Foundation

// Ces valeurs partent en base, remontent dans trois services et composent des clés de traduction.
// Recopiées en dur, une faute de frappe ne cassait pas la compilation : elle changeait seulement
// ce que l'écran affiche, ou renvoyait discrètement une opération dans la file de vérification.
enum ClassificationEvidence: String, CaseIterable {
    /// L'utilisateur a tranché lui-même.
    case user
    /// Le code d'opération de la banque le dit.
    case bankCode
    /// Le libellé le dit.
    case label
    /// L'autre compte du virement est un compte connu de l'utilisateur.
    case knownAccount
    /// Les deux jambes du virement ont été appariées entre comptes.
    case pairedAccounts
    /// Rien d'exploitable dans l'opération.
    case insufficient
    /// Opération importée avant que la provenance ne soit consignée.
    case legacy

    var localizationKey: String { "classification.evidence." + rawValue }
}

enum ClassificationConfidence: String, CaseIterable {
    case confirmed
    case high
    case medium
    case low

    var localizationKey: String { "classification.confidence." + rawValue }

    // L'échelle découle de la provenance, et d'elle seule.
    init(evidence: ClassificationEvidence) {
        switch evidence {
        case .user: self = .confirmed
        case .bankCode, .knownAccount: self = .high
        case .label, .pairedAccounts: self = .medium
        case .insufficient, .legacy: self = .low
        }
    }
}
