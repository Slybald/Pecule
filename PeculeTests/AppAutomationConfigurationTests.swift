import XCTest
@testable import Pecule

final class AppAutomationConfigurationTests: XCTestCase {
    func testBankStressScenarioIsIsolatedFromProductionAndDoesNotSeedDemoEntries() {
        let configuration = AppAutomationConfiguration.fromEnvironment(["PECULE_AUTOMATION_DATA_MODE": "bankStress"])
        XCTAssertTrue(configuration.usesInMemoryStore)
        XCTAssertTrue(configuration.usesStubBankGateway)
        XCTAssertFalse(configuration.shouldSeedOnReload)
        XCTAssertNil(AppAutomationConfiguration.inert.dataMode)
    }

    func testEmptyEnvironmentIsInert() {
        let configuration = AppAutomationConfiguration.fromEnvironment([:])

        XCTAssertFalse(configuration.usesInMemoryStore)
        XCTAssertNil(configuration.dataMode)
        XCTAssertFalse(configuration.disablesAnimations)
        XCTAssertFalse(configuration.usesStubBankGateway)
        XCTAssertTrue(configuration.showsPrivacyShield)
        XCTAssertFalse(configuration.shouldSeedOnReload)
    }

    func testFlagsAreParsedAndTheInMemoryStoreImpliesTheStubBank() {
        let configuration = AppAutomationConfiguration.fromEnvironment([
            "PECULE_AUTOMATION_DATA_MODE": "empty",
            "PECULE_AUTOMATION_DISABLE_ANIMATIONS": "1",
        ])

        XCTAssertTrue(configuration.usesInMemoryStore, "a data mode implies the in-memory store")
        XCTAssertEqual(configuration.dataMode, .empty)
        XCTAssertFalse(configuration.shouldSeedOnReload)
        XCTAssertTrue(configuration.disablesAnimations)
        XCTAssertTrue(configuration.usesStubBankGateway, "automation must never reach a real bank")
        XCTAssertFalse(configuration.showsPrivacyShield)
    }

    func testTheInertConfigurationNeverUsesTestDoubles() {
        let inert = AppAutomationConfiguration.inert

        XCTAssertFalse(inert.usesInMemoryStore)
        XCTAssertFalse(inert.usesStubBankGateway)
        XCTAssertFalse(inert.disablesAnimations)
    }
}
