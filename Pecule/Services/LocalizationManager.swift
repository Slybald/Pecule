import SwiftUI

/// Gère la langue de l’application. Par défaut : français.
/// L’utilisateur peut choisir une langue (ex. anglais) ou suivre la langue du système.
@MainActor
final class LocalizationManager: ObservableObject {
    nonisolated static let userDefaultsKey = "LifeOS.preferredLanguageCode"
    nonisolated static let systemLanguageCode = "__system__"
    nonisolated static let didChangeLanguageNotification = Notification.Name("Pecule.didChangeLanguage")

    /// Code langue (ex. "fr", "en") ou `nil` pour suivre la langue du système.
    @Published var preferredLanguageCode: String? {
        didSet {
            UserDefaults.standard.set(preferredLanguageCode ?? Self.systemLanguageCode, forKey: Self.userDefaultsKey)
            NotificationCenter.default.post(name: Self.didChangeLanguageNotification, object: preferredLanguageCode)
        }
    }

    /// Locale à injecter dans l’environnement pour que toute l’app utilise la langue choisie.
    var locale: Locale {
        Self.locale(for: preferredLanguageCode)
    }

    /// Langues proposées dans les réglages (identifiant → nom affiché dans la langue courante).
    nonisolated static let availableLanguages: [(code: String, nameKey: String)] = [
        ("fr", "settings.language.french"),
        ("en", "settings.language.english"),
    ]

    nonisolated static var currentAppLanguageCode: String? {
        let storedLanguageCode = UserDefaults.standard.string(forKey: Self.userDefaultsKey)

        switch storedLanguageCode {
        case Self.systemLanguageCode, nil:
            return nil
        case let code?:
            return code
        }
    }

    nonisolated static var currentAppLocale: Locale {
        locale(for: currentAppLanguageCode)
    }

    init() {
        let storedLanguageCode = UserDefaults.standard.string(forKey: Self.userDefaultsKey)

        switch storedLanguageCode {
        case Self.systemLanguageCode:
            preferredLanguageCode = nil
        case let code?:
            preferredLanguageCode = code
        case nil:
            preferredLanguageCode = "fr"
        }
    }

    func setLanguage(_ code: String?) {
        preferredLanguageCode = code
    }

    nonisolated private static func locale(for preferredLanguageCode: String?) -> Locale {
        guard let preferredLanguageCode, !preferredLanguageCode.isEmpty else {
            return Locale.current
        }

        if let regionCode = Locale.current.region?.identifier, !regionCode.isEmpty {
            return Locale(identifier: "\(preferredLanguageCode)_\(regionCode)")
        }

        return Locale(identifier: preferredLanguageCode)
    }
}
