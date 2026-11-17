import Foundation

struct AppAutomationConfiguration {
    enum DataMode: String {
        case seeded
        case empty
        case bankStress
    }

    let usesInMemoryStore: Bool
    let dataMode: DataMode?
    let disablesAnimations: Bool
    let usesStubBankGateway: Bool
    // Debug seulement, et seulement avec la base en mémoire : le premier essai d'ouverture échoue comme une
    // migration ratée, pour vérifier l'écran de reprise et « Réessayer » sans jamais toucher une vraie base.
    var simulatesStoreFailure = false

    var shouldSeedOnReload: Bool {
        usesInMemoryStore && dataMode == .seeded
    }

    var showsPrivacyShield: Bool {
        !usesInMemoryStore
    }

    // Production builds never honour PECULE_* flags: no in-memory store, no stub bank, no disabled animations.
    static let inert = AppAutomationConfiguration(usesInMemoryStore: false, dataMode: nil, disablesAnimations: false, usesStubBankGateway: false)

    static var current: AppAutomationConfiguration {
        #if DEBUG
        return fromEnvironment(ProcessInfo.processInfo.environment)
        #else
        return inert
        #endif
    }

    static func fromEnvironment(_ environment: [String: String]) -> AppAutomationConfiguration {
        let dataMode = DataMode(rawValue: environment["PECULE_AUTOMATION_DATA_MODE"] ?? "")
        let usesInMemoryStore = environment["PECULE_UI_TESTS_USE_IN_MEMORY_STORE"] == "1" || dataMode != nil || environment["XCTestConfigurationFilePath"] != nil

        return AppAutomationConfiguration(
            usesInMemoryStore: usesInMemoryStore,
            dataMode: dataMode,
            disablesAnimations: environment["PECULE_AUTOMATION_DISABLE_ANIMATIONS"] == "1",
            // Automation runs must never reach a real bank, so the in-memory store implies the stub gateway.
            usesStubBankGateway: environment["PECULE_AUTOMATION_BANK_MODE"] == "stub" || usesInMemoryStore,
            simulatesStoreFailure: usesInMemoryStore && environment["PECULE_AUTOMATION_SIMULATE_STORE_FAILURE"] == "1"
        )
    }
}
