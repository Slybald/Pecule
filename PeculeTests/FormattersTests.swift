import Foundation
import XCTest
@testable import Pecule

// Les formateurs de montants : lecture indépendante de la langue et de la région, écriture sans perte,
// devise toujours en euros. Chaque test fixe explicitement la locale : celle du simulateur ne doit jamais
// décider du résultat. Un simulateur en en_US donne une locale d'app à point décimal, qui cachait justement
// le défaut de relecture en français (constat m095).
final class FormattersTests: XCTestCase {
    private static let appLocaleIdentifiers = ["fr_FR", "en_US", "de_CH", "en_GB", "fr_CH"]

    private func decimal(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> Decimal {
        TestFixtures.decimal(text, file: file, line: line)
    }

    // MARK: - Écriture et aller-retour

    func testDecimalValueReadsBackWhatDecimalStringWritesInEveryAppLocale() {
        let values = ["0", "12.5", "12.34", "1234.56", "0.99", "-12.5", "0.005", "99999.99"]
        for identifier in Self.appLocaleIdentifiers {
            let locale = Locale(identifier: identifier)
            for text in values {
                let value = decimal(text)
                let written = Formatters.decimalString(for: value, locale: locale)
                XCTAssertEqual(
                    Formatters.decimalValue(from: written),
                    value,
                    "\(identifier) : « \(written) » doit se relire \(text)"
                )
            }
        }
    }

    func testDecimalStringKeepsTheExactValueWithTheLocaleSeparatorAndNoGrouping() {
        let french = Locale(identifier: "fr_FR"), english = Locale(identifier: "en_US")
        XCTAssertEqual(Formatters.decimalString(for: decimal("12.5"), locale: french), "12,5")
        XCTAssertEqual(Formatters.decimalString(for: decimal("12.5"), locale: english), "12.5")
        XCTAssertEqual(Formatters.decimalString(for: decimal("-12.5"), locale: french), "-12,5")
        XCTAssertEqual(Formatters.decimalString(for: decimal("0.005"), locale: french), "0,005", "aucun arrondi")
        XCTAssertEqual(Formatters.decimalString(for: decimal("1234567.891"), locale: french), "1234567,891", "aucun groupement")
        XCTAssertEqual(Formatters.decimalString(for: decimal("1234567.891"), locale: english), "1234567.891")
        XCTAssertEqual(Formatters.decimalString(for: 0, locale: french), "0")
        XCTAssertEqual(Formatters.decimalString(for: nil, locale: french), "")
    }

    func testDecimalStringFallsBackToThePointWhenTheLocaleSeparatorIsNeitherCommaNorPoint() {
        // Arabe : « ٫ ». Le pavé numérique et `decimalValue` ne le comprendraient pas.
        let arabic = Locale(identifier: "ar_SA")
        XCTAssertEqual(Formatters.decimalString(for: decimal("12.5"), locale: arabic), "12.5")
        XCTAssertEqual(Formatters.decimalValue(from: Formatters.decimalString(for: decimal("12.5"), locale: arabic)), decimal("12.5"))
    }

    func testAmountPlaceholderFollowsTheAppLocale() {
        XCTAssertEqual(Formatters.amountPlaceholder(locale: Locale(identifier: "fr_FR")), "0,00")
        XCTAssertEqual(Formatters.amountPlaceholder(locale: Locale(identifier: "en_US")), "0.00")
    }

    // m113 : les champs de montant portent un libellé VoiceOver localisé, et non plus l'exemple « 0,00 ».
    // Une clé absente du catalogue se lit comme la clé elle-même.
    func testAmountFieldAccessibilityLabelsExistInFrenchAndEnglish() {
        for key in ["budgetForm.amount.label", "manualAccountForm.balance.label", "goal.reservation.amount", "monthlyBudget.limit"] {
            for language in ["fr", "en"] {
                XCTAssertNotEqual(AppLocalizer.string(key, locale: Locale(identifier: language)), key, "\(language) : clé « \(key) » absente du catalogue")
            }
        }
        XCTAssertEqual(AppLocalizer.string("goal.reservation.amount", locale: Locale(identifier: "fr")), "Montant à réserver ou libérer")
        XCTAssertEqual(AppLocalizer.string("goal.reservation.amount", locale: Locale(identifier: "en")), "Amount to reserve or release")
    }

    // MARK: - Lecture

    func testDecimalValueTable() {
        let table: [(input: String, expected: String?)] = [
            // Virgule ou point, quelle que soit la locale.
            ("12,50", "12.5"), ("12.50", "12.5"),
            // Espace normale, insécable, fine insécable et fine : retirées.
            ("1 234,56", "1234.56"), ("1\u{00A0}234,56", "1234.56"), ("1\u{202F}234,56", "1234.56"), ("1\u{2009}234,56", "1234.56"),
            // Les deux séparateurs : le dernier est le décimal.
            ("1.234,56", "1234.56"), ("1,234.56", "1234.56"),
            ("1.234.567,89", "1234567.89"), ("1,234,567.89", "1234567.89"),
            // Un séparateur répété est un groupement de trois chiffres.
            ("1.234.567", "1234567"), ("1,234,567", "1234567"),
            // Signes : moins, plus, moins typographique U+2212.
            ("-12,5", "-12.5"), ("\u{2212}12,5", "-12.5"), ("+12,5", "12.5"), ("-,5", "-0.5"),
            // Séparateur décimal en tête ou en fin.
            ("12,", "12"), (",5", "0.5"), ("12.", "12"), (".5", "0.5"), ("1.234,", "1234"),
            // Apostrophes de groupement suisses.
            ("1'234.50", "1234.5"), ("1\u{2019}234,50", "1234.5"),
            // Un seul séparateur, une seule fois : c'est le décimal.
            ("1,234", "1.234"), ("0,005", "0.005"),
            // Symbole de l'euro, en tête ou en fin.
            ("250 €", "250"), ("12€", "12"), ("€12,50", "12.5"),
            // Espaces autour et zéros de tête.
            ("  12,5  ", "12.5"), ("12\n", "12"), ("007", "7"), ("0", "0"),
            // Refus : jamais une valeur partielle.
            ("12 € 50", nil), ("€€", nil),
            ("12abc", nil), ("1,2,3", nil), ("abc", nil), ("", nil), ("   ", nil), ("-", nil), ("+", nil),
            ("12.34.56", nil), ("1.234,56,7", nil), ("1.2,3", nil), ("12,34.567", nil), (".234.567", nil), ("1,234,", nil),
            (",", nil), (".", nil), ("--5", nil), ("5-", nil), ("1-2", nil), ("1e5", nil), ("NaN", nil),
            // Chiffres d'une autre écriture : `Decimal(string:)` rendrait un préfixe, donc refus.
            ("\u{0663}", nil), ("12\u{0663}", nil),
        ]
        for (input, expected) in table {
            XCTAssertEqual(
                Formatters.decimalValue(from: input),
                expected.map { decimal($0) },
                "« \(input) » devrait donner \(expected ?? "nil")"
            )
        }
    }

    // C004 : la lecture ne dépend plus de la locale de l'app (langue choisie + région de l'appareil). La région ne se
    // change pas depuis un test ; la langue, si : le résultat doit être identique dans toutes.
    func testDecimalValueDoesNotDependOnTheAppLanguage() {
        let key = LocalizationManager.userDefaultsKey
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        let inputs = ["12,50", "12.50", "1 234,56", "1.234,56", "1,234.56", "1.234.567", "-12,5", "12,", ",5", "12abc", "1,2,3", ""]
        var readings: [[Decimal?]] = []
        for language in ["fr", "en", LocalizationManager.systemLanguageCode] {
            UserDefaults.standard.set(language, forKey: key)
            readings.append(inputs.map { Formatters.decimalValue(from: $0) })
        }
        XCTAssertEqual(readings[0], readings[1], "fr et en")
        XCTAssertEqual(readings[0], readings[2], "fr et langue du système")
        XCTAssertEqual(readings[0].first, decimal("12.5"))
    }

    // MARK: - Champ prérempli

    func testAnUnmodifiedPrefilledFieldReturnsTheOriginalValueWithoutReadingItsText() {
        let french = Locale(identifier: "fr_FR")
        let original = decimal("83.34")
        let prefilled = Formatters.decimalString(for: original, locale: french)
        XCTAssertEqual(Formatters.decimalValue(from: prefilled, prefilledWith: original, locale: french), original)
        // « NaN » ne se relit pas : seule la valeur d'origine peut sortir d'un texte inchangé.
        let notANumber = Formatters.decimalValue(from: "NaN", prefilledWith: .nan, locale: french)
        XCTAssertEqual(notANumber?.isNaN, true)
    }

    func testAModifiedOrClearedPrefilledFieldIsReadFromItsText() {
        let french = Locale(identifier: "fr_FR")
        let original = decimal("12.5")
        XCTAssertEqual(Formatters.decimalValue(from: "13,5", prefilledWith: original, locale: french), decimal("13.5"))
        XCTAssertEqual(Formatters.decimalValue(from: "12,50", prefilledWith: original, locale: french), original, "même valeur, autre texte")
        XCTAssertNil(Formatters.decimalValue(from: "", prefilledWith: original, locale: french))
        XCTAssertNil(Formatters.decimalValue(from: "12abc", prefilledWith: original, locale: french))
        XCTAssertEqual(Formatters.decimalValue(from: "12,5", prefilledWith: nil, locale: french), original)
    }

    // MARK: - Devise

    func testCurrencyStringIsInEurosWhateverTheRegion() {
        let amount = decimal("1234.5")
        let identifiers: [String] = Self.appLocaleIdentifiers + ["fr_US", "en_AU"]
        for identifier in identifiers {
            let locale = Locale(identifier: identifier)
            let renderings: [(name: String, text: String)] = [
                ("currencyString", Formatters.currencyString(for: amount, locale: locale)),
                ("currencyString(EUR)", Formatters.currencyString(for: amount, currencyCode: "EUR", locale: locale)),
                ("compact ≥ 1000", Formatters.compactCurrencyString(for: amount, locale: locale)),
                ("compact < 1000", Formatters.compactCurrencyString(for: decimal("800"), locale: locale)),
                ("amountParts", Formatters.amountParts(for: amount, locale: locale).symbol),
            ]
            for (name, text) in renderings {
                XCTAssertTrue(text.contains("€"), "\(identifier), \(name) : « \(text) » doit porter « € »")
                for foreign in ["CHF", "£", "$", "EUR"] {
                    XCTAssertFalse(text.contains(foreign), "\(identifier), \(name) : « \(text) » ne doit pas contenir « \(foreign) »")
                }
            }
        }
    }

    func testCurrencyStringIsUnchangedInFrance() {
        let amount = decimal("1234.5")
        let reference = NumberFormatter()
        reference.numberStyle = .currency
        reference.minimumFractionDigits = 2
        reference.maximumFractionDigits = 2
        reference.locale = Locale(identifier: "fr_FR")
        XCTAssertEqual(
            Formatters.currencyString(for: amount, locale: Locale(identifier: "fr_FR")),
            reference.string(from: NSDecimalNumber(decimal: amount))
        )
    }

    func testAnExplicitCurrencyCodeIsKeptForAccountsInAnotherCurrency() {
        let amount = decimal("1234.5")
        XCTAssertTrue(Formatters.currencyString(for: amount, currencyCode: "USD", locale: Locale(identifier: "fr_FR")).contains("$"))
        XCTAssertTrue(Formatters.currencyString(for: amount, currencyCode: "GBP", locale: Locale(identifier: "en_GB")).contains("£"))
        XCTAssertTrue(Formatters.currencyString(for: amount, currencyCode: "CHF", locale: Locale(identifier: "fr_CH")).contains("CHF"))
        XCTAssertFalse(Formatters.currencyString(for: amount, currencyCode: "USD", locale: Locale(identifier: "fr_FR")).contains("€"))
    }
}
