import AppIntents
import Security
import XCTest
@testable import Pecule

// Constat 14 de l'audit : quatre protections que rien ne gardait. Les changer laissait la suite verte.
final class ProtectionGuardsTests: XCTestCase {
    // Un jeton bancaire ne doit ni être synchronisé, ni migrer vers un autre appareil, ni rester illisible après un redémarrage.
    func testKeychainItemsStayOnThisDeviceAndOpenAfterFirstUnlock() throws {
        let service = "com.nicolas.Pecule.tests.\(UUID().uuidString)"
        let store = KeychainSecretStore(service: service)
        defer { try? store.setSecret(nil, for: "token") }
        try store.setSecret("secret", for: "token")

        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "token",
            kSecReturnAttributes as String: true,
        ] as CFDictionary, &result)

        XCTAssertEqual(status, errSecSuccess)
        let attributes = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }

    // Solde et saisie exigent un iPhone déverrouillé, même via Siri.
    func testBalanceAndPurchaseIntentsRequireAuthentication() {
        XCTAssertEqual(LogPurchaseIntent.authenticationPolicy, .requiresAuthentication)
        XCTAssertEqual(TotalBalanceIntent.authenticationPolicy, .requiresAuthentication)
    }

    // Arrondi bancaire : 0,125 → 0,12 et 0,135 → 0,14 (l'arrondi « au plus loin » donnerait 0,13 et 0,14).
    func testMoneyRoundsToEvenOnTheMidpoint() {
        XCTAssertEqual(TestFixtures.decimal("0.125").currencyRounded, TestFixtures.decimal("0.12"))
        XCTAssertEqual(TestFixtures.decimal("0.135").currencyRounded, TestFixtures.decimal("0.14"))
        XCTAssertEqual(TestFixtures.decimal("2.5").rounded(scale: 0), 2)
    }

    // Seul https est accepté pour l'URL d'identité : un jeton ne part jamais en clair.
    @MainActor
    func testIdentityURLMustBeHTTPS() {
        XCTAssertNotNil(PeculeRuntime.identityURL(from: "https://identity.example.com"))
        XCTAssertNil(PeculeRuntime.identityURL(from: "http://identity.example.com"))
        XCTAssertNil(PeculeRuntime.identityURL(from: "ftp://identity.example.com"))
        XCTAssertNil(PeculeRuntime.identityURL(from: "https://"))
        XCTAssertNil(PeculeRuntime.identityURL(from: nil))
    }
}
