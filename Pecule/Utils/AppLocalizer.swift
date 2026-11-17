import Foundation

enum AppLocalizer {
    static func string(_ key: String, locale: Locale) -> String {
        localizedBundle(for: locale).localizedString(forKey: key, value: key, table: nil)
    }

    static func string(_ key: String) -> String {
        string(key, locale: LocalizationManager.currentAppLocale)
    }

    static func format(_ key: String, locale: Locale, _ arguments: CVarArg...) -> String {
        format(key, locale: locale, arguments)
    }

    // For keys whose catalogue entry has plural variations (one/other): the bundle returns the format with its
    // plural rule attached, and String(format:locale:) picks the form for the number. Use it only for such keys;
    // `format` is the strict renderer for the others.
    static func pluralFormat(_ key: String, locale: Locale, _ arguments: CVarArg...) -> String {
        String(format: string(key, locale: locale), locale: locale, arguments: arguments)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        let locale = LocalizationManager.currentAppLocale
        return format(key, locale: locale, arguments)
    }

    private static func format(_ key: String, locale: Locale, _ arguments: [CVarArg]) -> String {
        let localizedFormat = string(key, locale: locale)
        return render(localizedFormat, locale: locale, arguments: arguments)
            ?? render(key, locale: locale, arguments: arguments)
            ?? key
    }

    // The catalogue uses only object and integer placeholders. Never hand an unchecked
    // translation to C varargs: a literal "% d" can read a nonexistent argument and crash.
    // Unsupported/mismatched formats fail safely and fall back to the source key.
    static func render(_ template: String, locale: Locale, arguments: [CVarArg]) -> String? {
        var result = ""
        var cursor = template.startIndex
        var sequentialIndex = 0
        var usedArguments = Set<Int>()
        while cursor < template.endIndex {
            guard template[cursor] == "%" else {
                result.append(template[cursor])
                cursor = template.index(after: cursor)
                continue
            }
            cursor = template.index(after: cursor)
            guard cursor < template.endIndex else { return nil }
            if template[cursor] == "%" {
                result.append("%")
                cursor = template.index(after: cursor)
                continue
            }
            let positionStart = cursor
            while cursor < template.endIndex, template[cursor].isASCII, template[cursor].isNumber {
                cursor = template.index(after: cursor)
            }
            let argumentIndex: Int
            if cursor != positionStart {
                guard cursor < template.endIndex, template[cursor] == "$",
                      let position = Int(template[positionStart..<cursor]), position > 0 else { return nil }
                argumentIndex = position - 1
                cursor = template.index(after: cursor)
            } else {
                argumentIndex = sequentialIndex
                sequentialIndex += 1
            }
            guard arguments.indices.contains(argumentIndex), cursor < template.endIndex else { return nil }
            let argument = arguments[argumentIndex]
            if template[cursor] == "@" {
                guard let value = argument as? String else { return nil }
                result += value
                cursor = template.index(after: cursor)
            } else if template[cursor...].hasPrefix("lld") {
                let value: Int64
                switch argument {
                case let integer as Int: value = Int64(integer)
                case let integer as Int64: value = integer
                default: return nil
                }
                // This format and its argument type are constants, never translation-controlled.
                result += String(format: "%lld", locale: locale, value)
                cursor = template.index(cursor, offsetBy: 3)
            } else {
                return nil
            }
            usedArguments.insert(argumentIndex)
        }
        guard usedArguments == Set(arguments.indices) else { return nil }
        return result
    }

    private static func localizedBundle(for locale: Locale) -> Bundle {
        let baseBundle = Bundle.main
        let requestedLanguageCode = locale.language.languageCode?.identifier
            ?? LocalizationManager.currentAppLanguageCode
            ?? Locale.current.language.languageCode?.identifier

        guard let requestedLanguageCode else {
            return baseBundle
        }

        let preferredLocalization = Bundle.preferredLocalizations(
            from: baseBundle.localizations,
            forPreferences: [requestedLanguageCode]
        ).first

        guard
            let preferredLocalization,
            let bundlePath = baseBundle.path(forResource: preferredLocalization, ofType: "lproj"),
            let localizedBundle = Bundle(path: bundlePath)
        else {
            return baseBundle
        }

        return localizedBundle
    }
}
