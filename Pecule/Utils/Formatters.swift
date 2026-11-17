import Foundation

enum Formatters {
    // Les montants de l'app sont en euros, quelle que soit la région de l'appareil : sans devise explicite,
    // le formateur prenait celle de la région (CHF, £, $). Avec le seul code EUR, certaines régions
    // (de_CH, en_AU) écrivent encore « EUR » au lieu de « € » : le symbole de l'euro est donc imposé aussi.
    private static func currencyFormatter(
        currencyCode: String = "EUR",
        locale: Locale = LocalizationManager.currentAppLocale
    ) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        formatter.locale = locale
        formatter.currencyCode = currencyCode
        if currencyCode == "EUR" {
            formatter.currencySymbol = "€"
        }
        return formatter
    }

    private static func shortDateFormatter(locale: Locale = LocalizationManager.currentAppLocale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.locale = locale
        return formatter
    }

    private static func monthYearFormatter(locale: Locale = LocalizationManager.currentAppLocale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("LLLL yyyy")
        return formatter
    }

    private static func percentFormatter(locale: Locale = LocalizationManager.currentAppLocale) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        formatter.locale = locale
        return formatter
    }

    static func currencyString(for value: Decimal, locale: Locale = LocalizationManager.currentAppLocale) -> String {
        let number = NSDecimalNumber(decimal: value)
        return currencyFormatter(locale: locale).string(from: number) ?? number.stringValue
    }

    // Pour un compte dans une autre devise : le code reste explicite.
    static func currencyString(for value: Decimal, currencyCode: String, locale: Locale = LocalizationManager.currentAppLocale) -> String {
        let formatter = currencyFormatter(currencyCode: currencyCode, locale: locale)
        let number = NSDecimalNumber(decimal: value)
        return formatter.string(from: number) ?? "\(number.stringValue) \(currencyCode)"
    }

    static func dateString(for date: Date) -> String {
        shortDateFormatter().string(from: date)
    }

    static func dateTimeString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = LocalizationManager.currentAppLocale
        return formatter.string(from: date)
    }

    static func monthYearString(for date: Date) -> String {
        monthYearFormatter().string(from: date)
    }

    // "1,2 k€" on chart axes, "800 €" below a thousand.
    static func compactCurrencyString(for value: Decimal, currencyCode: String = "EUR", locale: Locale = LocalizationManager.currentAppLocale) -> String {
        let number = NSDecimalNumber(decimal: value).doubleValue
        guard abs(number) >= 1000 else {
            return currencyString(for: value.currencyRounded, currencyCode: currencyCode, locale: locale)
                .replacingOccurrences(of: ",00", with: "")
        }
        let thousands = number / 1000
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = abs(thousands) >= 10 ? 0 : 1
        let symbol = currencyCode == "EUR" ? "€" : currencyCode
        return (formatter.string(from: NSNumber(value: thousands)) ?? "\(thousands)") + "\u{202F}k" + symbol
    }

    // Integer digits, fraction digits and symbol split apart so a hero number can shrink its cents.
    static func amountParts(for value: Decimal, currencyCode: String = "EUR", locale: Locale = LocalizationManager.currentAppLocale) -> (integer: String, fraction: String?, symbol: String) {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        let magnitude = NSDecimalNumber(decimal: abs(value))
        let text = formatter.string(from: magnitude) ?? "\(magnitude)"
        let separator = formatter.decimalSeparator ?? ","
        let symbol = currencyCode == "EUR" ? "€" : currencyCode
        guard let range = text.range(of: separator, options: .backwards) else {
            return (text, nil, symbol)
        }
        return (String(text[..<range.lowerBound]), String(text[range.lowerBound...]), symbol)
    }

    static func percentString(for value: Double) -> String {
        percentFormatter().string(from: NSNumber(value: value)) ?? String(format: "%.0f%%", value * 100)
    }

    // Le séparateur que le pavé numérique propose et que `decimalValue(from:)` comprend : « , » ou « . ».
    // Toute autre marque (« ٫ » en arabe) retombe sur le point, pour que le champ reste relisible.
    private static func decimalMark(for locale: Locale) -> String {
        locale.decimalSeparator == "," ? "," : "."
    }

    // Le texte dont on préremplit un champ de montant : la valeur exacte, sans arrondi ni groupement,
    // avec le séparateur décimal de la locale de l'app. `decimalValue(from:)` le relit sans perte.
    static func decimalString(for value: Decimal?, locale: Locale = LocalizationManager.currentAppLocale) -> String {
        guard let value else {
            return ""
        }

        // `stringValue` est la forme POSIX exacte (« 12.5 », « 0.005 ») quelle que soit la locale :
        // seul le point est remplacé.
        let posix = NSDecimalNumber(decimal: value).stringValue
        let mark = decimalMark(for: locale)
        return mark == "." ? posix : posix.replacingOccurrences(of: ".", with: mark)
    }

    // Exemple de saisie d'un montant, sans symbole : « 0,00 » ou « 0.00 » selon la locale de l'app.
    static func amountPlaceholder(locale: Locale = LocalizationManager.currentAppLocale) -> String {
        "0" + decimalMark(for: locale) + "00"
    }

    // Lecture d'un montant saisi ou collé, indépendante de la langue de l'app et de la région de
    // l'appareil : « 12,50 », « 12.50 », « 1 234,56 », « 1.234,56 », « 1,234.56 » et « 1'234.56 » sont lus
    // pareil. Rend nil plutôt qu'une valeur partielle : « 12abc » n'est pas 12.
    static func decimalValue(from input: String) -> Decimal? {
        // Les espaces de toute sorte (normale, insécable U+00A0, fine U+2009, fine insécable U+202F) et
        // les apostrophes de groupement suisses ne portent aucun sens : ils sont retirés.
        var scalars = input.unicodeScalars.filter { !$0.properties.isWhitespace && $0 != "'" && $0 != "\u{2019}" }

        // Le symbole de l'euro (U+20AC), en tête (« €12,50 ») ou en fin (« 250 € »), n'est pas non plus un montant.
        // Un seul de chaque côté : un « € » au milieu (« 12 € 50 ») ou doublé (« €€12 ») reste et fait refuser la saisie.
        if scalars.first == "\u{20AC}" { scalars.removeFirst() }
        if scalars.last == "\u{20AC}" { scalars.removeLast() }

        // Un signe initial : « + », « - » ou le signe moins typographique U+2212.
        var sign = ""
        if let first = scalars.first, first == "+" || first == "-" || first == "\u{2212}" {
            sign = first == "+" ? "" : "-"
            scalars.removeFirst()
        }

        // Ensuite des chiffres ASCII, des points et des virgules, rien d'autre. Les chiffres d'autres
        // écritures sont refusés : `Decimal(string:)` s'arrêterait au premier et rendrait un préfixe.
        guard !scalars.isEmpty, scalars.allSatisfy({ ($0.value >= 48 && $0.value <= 57) || $0 == "." || $0 == "," }) else {
            return nil
        }
        var body = ""
        body.unicodeScalars.append(contentsOf: scalars)

        guard let parts = separatedParts(of: body) else {
            return nil
        }

        var integerDigits = String(parts.integer)
        if let grouping = parts.grouping {
            // Un groupement n'est valide que si chaque groupe après le premier compte trois chiffres :
            // « 1.234.567 » vaut 1 234 567, « 1,2,3 » ne vaut rien.
            let groups = parts.integer.split(separator: grouping, omittingEmptySubsequences: false)
            guard let head = groups.first, !head.isEmpty, groups.dropFirst().allSatisfy({ $0.count == 3 }) else {
                return nil
            }
            integerDigits = groups.joined()
        }
        // Un séparateur décimal en tête (« ,5 ») ou en fin (« 12, ») est toléré ; sans aucun chiffre, non.
        guard !integerDigits.isEmpty || !parts.fraction.isEmpty else {
            return nil
        }

        let normalized = sign
            + (integerDigits.isEmpty ? "0" : integerDigits)
            + (parts.fraction.isEmpty ? "" : "." + parts.fraction)
        // Dernier garde-fou : toute la chaîne doit être consommée, jamais un préfixe.
        guard normalized.range(of: #"\A-?[0-9]+(\.[0-9]+)?\z"#, options: .regularExpression) != nil else {
            return nil
        }
        return Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX"))
    }

    // Répartit un texte fait de chiffres, de points et de virgules en partie entière, partie décimale et
    // séparateur de groupement. Les deux séparateurs : le dernier est le décimal et n'apparaît qu'une
    // fois, l'autre groupe les milliers. Un seul type de séparateur : une fois, c'est le décimal ;
    // plusieurs fois, c'est du groupement.
    private static func separatedParts(of body: String) -> (integer: Substring, fraction: Substring, grouping: Character?)? {
        guard let lastIndex = body.lastIndex(where: { $0 == "." || $0 == "," }) else {
            return (body[...], "", nil)
        }
        let last = body[lastIndex]
        let other: Character = last == "." ? "," : "."
        let integer = body[..<lastIndex]
        let fraction = body[body.index(after: lastIndex)...]
        let occurrences = body.filter { $0 == last }.count

        if body.contains(other) {
            return occurrences == 1 ? (integer, fraction, other) : nil
        }
        return occurrences == 1 ? (integer, fraction, nil) : (body[...], "", last)
    }

    // Lecture d'un champ de montant prérempli avec `decimalString(for: original)`. Tant que le texte est
    // resté celui du préremplissage, la valeur d'origine est rendue telle quelle, sans relecture : un
    // champ que l'utilisateur n'a pas touché ne peut jamais altérer le montant qu'il affichait.
    static func decimalValue(
        from input: String,
        prefilledWith original: Decimal?,
        locale: Locale = LocalizationManager.currentAppLocale
    ) -> Decimal? {
        if let original, input == decimalString(for: original, locale: locale) {
            return original
        }
        return decimalValue(from: input)
    }
}
