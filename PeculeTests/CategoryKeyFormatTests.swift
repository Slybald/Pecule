import XCTest
@testable import Pecule

// La clé d'une catégorie personnalisée est unique en base. Changer son préfixe, son empreinte ou
// sa normalisation re-clérait silencieusement toutes les catégories créées par l'utilisateur :
// les anciennes deviendraient orphelines et les budgets qui s'y rattachent muets. Aucun test ne
// fixait ce format, alors que c'est précisément ce qu'on ne peut plus modifier après diffusion.
final class CategoryKeyFormatTests: XCTestCase {
    // Valeur témoin : SHA-256 de « cafe », la forme repliée de « Café ».
    private let cafeKey = "custom:a860b858265b22dad3aaf1165cfc2936daf1d3d86e0b7b77e3cc07f59f96858f"

    func testACustomCategoryKeepsItsPrefixAndItsDigestOnDisk() {
        XCTAssertEqual(ExpenseCategory.custom("Café").rawValue, cafeKey)
        XCTAssertEqual(CategoryRecord(name: "Café").key, cafeKey)
    }

    func testTheKeyShapeIsAPrefixFollowedBySixtyFourHexadecimalCharacters() {
        let key = ExpenseCategory.custom("Abonnements perso").rawValue
        let digest = key.dropFirst("custom:".count)
        XCTAssertTrue(key.hasPrefix("custom:"), "le préfixe distingue une catégorie personnalisée d'une catégorie fournie")
        XCTAssertEqual(digest.count, 64)
        XCTAssertTrue(digest.allSatisfy { $0.isHexDigit && !$0.isUppercase }, "empreinte hexadécimale en minuscules")
    }

    // La normalisation fait partie du contrat : deux saisies équivalentes ne doivent pas créer
    // deux catégories concurrentes, et une catégorie existante doit être retrouvée telle quelle.
    func testNamesDifferingOnlyByCaseAccentOrSpacingShareOneKey() {
        for variant in ["Café", "café", "CAFE", "  cafÉ  ", "Cafe"] {
            XCTAssertEqual(
                ExpenseCategory.custom(variant).rawValue,
                cafeKey,
                "« \(variant) » doit retrouver la catégorie existante"
            )
        }
    }

    func testTwoDifferentNamesDoNotCollide() {
        XCTAssertNotEqual(
            ExpenseCategory.custom("Café").rawValue,
            ExpenseCategory.custom("Cafétéria").rawValue
        )
    }

    // Les catégories fournies gardent une clé lisible, sans préfixe ni empreinte : une bascule
    // accidentelle vers la forme personnalisée détacherait toutes les règles de budget d'origine.
    func testSuppliedCategoriesKeepTheirPlainKey() {
        XCTAssertEqual(ExpenseCategory.other.rawValue, "other")
        XCTAssertEqual(ExpenseCategory.groceries.rawValue, "groceries")
        for category in ExpenseCategory.allCases {
            XCTAssertFalse(category.rawValue.hasPrefix("custom:"), "\(category.rawValue) est une catégorie fournie")
        }
        XCTAssertEqual(ExpenseCategory.canonicalKey(for: "Groceries"), "groceries")
        XCTAssertEqual(ExpenseCategory.canonicalKey(for: "   "), "other", "une saisie vide retombe sur Autre")
    }
}
