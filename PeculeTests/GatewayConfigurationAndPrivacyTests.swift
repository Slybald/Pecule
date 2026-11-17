import SwiftUI
import XCTest
@testable import Pecule

@MainActor
final class GatewayConfigurationAndPrivacyTests: XCTestCase {
    private func makeAppState() throws -> AppState {
        AppState(
            dataStore: try TestFixtures.makeDataStore(),
            bankGateway: LiveBankGatewayClient(configurationProvider: { nil }),
            bankGatewayConfigurationStore: BankGatewayConfigurationStore(secretStore: InMemorySecretStore())
        )
    }

    func testBlankTokenKeepsTheStoredSecretAndIsRejectedWithoutOne() throws {
        let appState = try makeAppState()
        let url = URL(string: "https://gateway.test")!
        XCTAssertFalse(appState.isBankGatewayConfigured)

        XCTAssertThrowsError(try appState.saveBankGatewayConfiguration(baseURL: url, bearerToken: "  ")) { error in
            XCTAssertEqual(error as? BankGatewayConfigurationError, .missingToken)
        }
        XCTAssertFalse(appState.isBankGatewayConfigured)

        try appState.saveBankGatewayConfiguration(baseURL: url, bearerToken: " secret-1 ")
        XCTAssertTrue(appState.isBankGatewayConfigured)
        XCTAssertEqual(appState.currentBankGatewayConfiguration?.bearerToken, "secret-1")

        let newURL = URL(string: "https://gateway.test/v2")!
        try appState.saveBankGatewayConfiguration(baseURL: newURL, bearerToken: nil)
        XCTAssertEqual(appState.currentBankGatewayConfiguration, BankGatewayConfiguration(baseURL: newURL, bearerToken: "secret-1"))

        try appState.saveBankGatewayConfiguration(baseURL: newURL, bearerToken: "secret-2")
        XCTAssertEqual(appState.currentBankGatewayConfiguration?.bearerToken, "secret-2")

        try appState.clearBankGatewayConfiguration()
        XCTAssertFalse(appState.isBankGatewayConfigured)
        XCTAssertNil(appState.currentBankGatewayConfiguration)
    }

    func testPrivacyShieldShowsOnlyWhenInactiveOutsideAutomation() {
        let production = AppAutomationConfiguration(usesInMemoryStore: false, dataMode: nil, disablesAnimations: false, usesStubBankGateway: false)
        let automation = AppAutomationConfiguration(usesInMemoryStore: true, dataMode: .seeded, disablesAnimations: true, usesStubBankGateway: true)

        XCTAssertFalse(PrivacyShieldPolicy.shouldShow(scenePhase: .active, automation: production))
        XCTAssertTrue(PrivacyShieldPolicy.shouldShow(scenePhase: .inactive, automation: production))
        XCTAssertTrue(PrivacyShieldPolicy.shouldShow(scenePhase: .background, automation: production))
        XCTAssertFalse(PrivacyShieldPolicy.shouldShow(scenePhase: .background, automation: automation))
    }
}
