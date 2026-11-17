import Foundation
import CryptoKit
import Synchronization

struct ExpenseCategory: RawRepresentable, Codable, CaseIterable, Hashable, Identifiable {
    let rawValue: String
    private var customName: String?
    init?(rawValue: String) {
        guard Self.allCases.contains(where: { $0.rawValue == rawValue }) else { return nil }
        self.rawValue = rawValue
    }
    private init(builtin: String) { rawValue = builtin }
    static func custom(_ name: String) -> ExpenseCategory {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let key = SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
        return ExpenseCategory(key: "custom:" + key, name: trimmed)
    }
    private init(key: String, name: String) { rawValue = key; customName = name }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.rawValue == rhs.rawValue }
    func hash(into hasher: inout Hasher) { hasher.combine(rawValue) }
    static let subscriptions = ExpenseCategory(builtin: "subscriptions")
    static let insurance = ExpenseCategory(builtin: "insurance")
    static let groceries = ExpenseCategory(builtin: "groceries")
    static let fuel = ExpenseCategory(builtin: "fuel")
    static let transport = ExpenseCategory(builtin: "transport")
    static let housing = ExpenseCategory(builtin: "housing")
    static let health = ExpenseCategory(builtin: "health")
    static let leisure = ExpenseCategory(builtin: "leisure")
    static let shopping = ExpenseCategory(builtin: "shopping")
    static let education = ExpenseCategory(builtin: "education")
    static let other = ExpenseCategory(builtin: "other")
    static let allCases: [ExpenseCategory] = [.subscriptions, .insurance, .groceries, .fuel, .transport, .housing, .health, .leisure, .shopping, .education, .other]

    var id: String { rawValue }

    static var budgetCategories: [String] {
        allCases.map(\.storageValue)
    }

    var storageValue: String {
        switch self {
        case .subscriptions:
            return "Subscriptions"
        case .insurance:
            return "Insurance"
        case .groceries:
            return "Groceries"
        case .fuel:
            return "Fuel"
        case .transport:
            return "Transport"
        case .housing:
            return "Housing"
        case .health:
            return "Health"
        case .leisure:
            return "Leisure"
        case .shopping:
            return "Shopping"
        case .education:
            return "Education"
        case .other:
            return "Other"
        default: return customName ?? "Other"
        }
    }

    func displayName(locale: Locale = LocalizationManager.currentAppLocale) -> String {
        if let customName { return customName }
        let localizedValue = AppLocalizer.string(localizationKey, locale: locale)
        return localizedValue == localizationKey ? fallbackDisplayName(locale: locale) : localizedValue
    }

    init?(matching value: String) {
        let lookupKey = Self.normalizedLookupKey(for: value)

        guard !lookupKey.isEmpty else {
            return nil
        }

        if let directMatch = Self(rawValue: lookupKey) {
            self = directMatch
            return
        }

        guard let category = Self.aliasLookup[lookupKey] else {
            return nil
        }

        self = category
    }

    static func standardizedStorageValue(for value: String?) -> String? {
        guard let value, let category = ExpenseCategory(matching: value) else {
            return nil
        }

        return category.storageValue
    }

    // Résoudre une catégorie compile une expression régulière de normalisation et, pour un nom
    // inconnu, calcule une empreinte SHA-256. C'est appelé par opération sur des chemins de rendu :
    // le résultat ne dépend que de la chaîne, on le retient. Cache borné, comme ailleurs.
    private static let canonicalCacheLimit = 4_096
    private static let canonicalCache = Mutex<[String: ExpenseCategory]>([:])

    static func canonicalCategory(for value: String?) -> ExpenseCategory {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return .other }
        if let cached = canonicalCache.withLock({ $0[trimmed] }) {
            return cached
        }
        let resolved = ExpenseCategory(matching: trimmed) ?? .custom(trimmed)
        canonicalCache.withLock { storage in
            if storage.count >= canonicalCacheLimit {
                storage.removeAll(keepingCapacity: true)
            }
            storage[trimmed] = resolved
        }
        return resolved
    }

    static func canonicalStorageValue(for value: String?) -> String {
        canonicalCategory(for: value).storageValue
    }

    static func canonicalKey(for value: String?) -> String {
        canonicalCategory(for: value).rawValue
    }

    static func formStorageValue(for value: String?) -> String {
        let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if let standardizedValue = standardizedStorageValue(for: trimmedValue) {
            return standardizedValue
        }

        return trimmedValue.isEmpty ? ExpenseCategory.other.storageValue : trimmedValue
    }

    static func displayName(forStoredValue value: String, locale: Locale = LocalizationManager.currentAppLocale) -> String {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)

        if let category = ExpenseCategory(matching: trimmedValue) {
            return category.displayName(locale: locale)
        }

        return trimmedValue.isEmpty ? ExpenseCategory.other.displayName(locale: locale) : trimmedValue
    }

    private var localizationKey: String {
        switch self {
        case .subscriptions:
            return "expenseCategory.subscriptions"
        case .insurance:
            return "expenseCategory.insurance"
        case .groceries:
            return "expenseCategory.groceries"
        case .fuel:
            return "expenseCategory.fuel"
        case .transport:
            return "expenseCategory.transport"
        case .housing:
            return "expenseCategory.housing"
        case .health:
            return "expenseCategory.health"
        case .leisure:
            return "expenseCategory.leisure"
        case .shopping:
            return "expenseCategory.shopping"
        case .education:
            return "expenseCategory.education"
        case .other:
            return "expenseCategory.other"
        default: return "expenseCategory.other"
        }
    }

    private var aliases: [String] {
        switch self {
        case .subscriptions:
            return [
                "subscription",
                "streaming",
                "music",
                "storage",
                "membership",
                "memberships",
                "recurring"
            ]
        case .insurance:
            return [
                "insurance",
                "insurances",
                "assurance",
                "assurances",
                "security",
                "protection"
            ]
        case .groceries:
            return [
                "grocery",
                "groceries",
                "food",
                "dining",
                "restaurant",
                "restaurants",
                "courses",
                "alimentation",
                "supermarket",
                "market"
            ]
        case .fuel:
            return [
                "fuel",
                "gas",
                "gasoline",
                "petrol",
                "essence",
                "carburant",
                "diesel"
            ]
        case .transport:
            return [
                "transport",
                "transportation",
                "travel",
                "commute",
                "commuting",
                "transit",
                "taxi",
                "uber",
                "parking",
                "toll",
                "tolls",
                "train",
                "bus",
                "metro",
                "rideshare"
            ]
        case .housing:
            return [
                "housing",
                "home",
                "household",
                "rent",
                "mortgage",
                "utilities",
                "living",
                "logement",
                "maison",
                "habitation"
            ]
        case .health:
            return [
                "health",
                "fitness",
                "medical",
                "medicine",
                "pharmacy",
                "wellness",
                "gym",
                "sport",
                "sante",
                "care"
            ]
        case .leisure:
            return [
                "leisure",
                "entertainment",
                "fun",
                "hobby",
                "hobbies",
                "gaming",
                "games",
                "movie",
                "movies",
                "culture"
            ]
        case .shopping:
            return [
                "shopping",
                "retail",
                "tech",
                "technology",
                "electronics",
                "work",
                "office",
                "clothing",
                "fashion",
                "gadgets",
                "home office"
            ]
        case .education:
            return [
                "education",
                "learning",
                "course",
                "school",
                "study",
                "studies",
                "training",
                "books",
                "tuition",
                "formation"
            ]
        case .other:
            return [
                "other",
                "misc",
                "miscellaneous",
                "autre",
                "divers",
                "family",
                "general",
                "unknown"
            ]
        default: return []
        }
    }

    private func fallbackDisplayName(locale: Locale) -> String {
        let languageCode = locale.language.languageCode?.identifier ?? "en"

        guard languageCode == "fr" else {
            return storageValue
        }

        switch self {
        case .subscriptions:
            return "Abonnements"
        case .insurance:
            return "Assurances"
        case .groceries:
            return "Courses"
        case .fuel:
            return "Essence"
        case .transport:
            return "Transport"
        case .housing:
            return "Logement"
        case .health:
            return "Sante"
        case .leisure:
            return "Loisirs"
        case .shopping:
            return "Achats"
        case .education:
            return "Education"
        case .other:
            return "Autre"
        default: return customName ?? "Autre"
        }
    }

    private static let aliasLookup: [String: ExpenseCategory] = {
        allCases.reduce(into: [String: ExpenseCategory]()) { lookup, category in
            for alias in category.aliases {
                lookup[normalizedLookupKey(for: alias)] = category
            }
        }
    }()

    private static func normalizedLookupKey(for value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

// Explicit so retroactive protocol conformances (App Intents) can rely on it from other files.
extension ExpenseCategory: Sendable {}
