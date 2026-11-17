import XCTest
@testable import Pecule

// Les provenances et les niveaux de confiance composent des clés de traduction. Une valeur
// ajoutée sans sa traduction ne casse rien à la compilation : l'écran affiche la clé brute,
// « classification.evidence.something », au milieu d'une fiche d'opération.
final class ClassificationVocabularyTests: XCTestCase {
    private let locales = [Locale(identifier: "fr"), Locale(identifier: "en")]

    func testEveryEvidenceValueIsTranslatedInBothLanguages() {
        for evidence in ClassificationEvidence.allCases {
            for locale in locales {
                let translated = AppLocalizer.string(evidence.localizationKey, locale: locale)
                XCTAssertNotEqual(
                    translated,
                    evidence.localizationKey,
                    "« \(evidence.rawValue) » n'a pas de traduction en \(locale.identifier)"
                )
            }
        }
    }

    func testEveryConfidenceValueIsTranslatedInBothLanguages() {
        for confidence in ClassificationConfidence.allCases {
            for locale in locales {
                let translated = AppLocalizer.string(confidence.localizationKey, locale: locale)
                XCTAssertNotEqual(translated, confidence.localizationKey, "« \(confidence.rawValue) » sans traduction")
            }
        }
    }

    func testEveryCreditNatureIsTranslatedInBothLanguages() {
        for nature in CreditNature.allCases {
            for locale in locales {
                let key = "transaction.nature." + nature.rawValue
                XCTAssertNotEqual(AppLocalizer.string(key, locale: locale), key, "« \(nature.rawValue) » sans traduction")
            }
        }
    }

    // L'échelle de confiance découle de la provenance : c'est cette correspondance qui décide
    // qu'une opération part ou non dans la file de vérification.
    func testTheConfidenceScaleFollowsTheEvidence() {
        XCTAssertEqual(ClassificationConfidence(evidence: .user), .confirmed)
        XCTAssertEqual(ClassificationConfidence(evidence: .bankCode), .high)
        XCTAssertEqual(ClassificationConfidence(evidence: .knownAccount), .high)
        XCTAssertEqual(ClassificationConfidence(evidence: .label), .medium)
        XCTAssertEqual(ClassificationConfidence(evidence: .pairedAccounts), .medium)
        XCTAssertEqual(ClassificationConfidence(evidence: .insufficient), .low)
        XCTAssertEqual(ClassificationConfidence(evidence: .legacy), .low)
    }

    // Les valeurs partent en base : les renommer re-classerait silencieusement l'historique.
    func testStoredValuesKeepTheirExactSpelling() {
        XCTAssertEqual(
            Set(ClassificationEvidence.allCases.map(\.rawValue)),
            ["user", "bankCode", "label", "knownAccount", "pairedAccounts", "insufficient", "legacy"]
        )
        XCTAssertEqual(
            Set(ClassificationConfidence.allCases.map(\.rawValue)),
            ["confirmed", "high", "medium", "low"]
        )
    }
}
