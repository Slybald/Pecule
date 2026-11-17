import XCTest
@testable import Pecule

final class SecretStoreTests: XCTestCase {
    func testInMemoryStoreRoundTrip() throws {
        let store = InMemorySecretStore(initialValues: ["a": "1"])

        XCTAssertEqual(try store.secret(for: "a"), "1")
        XCTAssertNil(try store.secret(for: "b"))
        try store.setSecret("2", for: "b")
        XCTAssertEqual(try store.secret(for: "b"), "2")
        try store.setSecret(nil, for: "a")
        XCTAssertNil(try store.secret(for: "a"))
    }

    func testKeychainStoreRoundTrip() throws {
        let store = KeychainSecretStore(service: "com.nicolas.Pecule.tests.\(UUID().uuidString)")
        let key = "token"
        defer { try? store.setSecret(nil, for: key) }

        XCTAssertNil(try store.secret(for: key))
        try store.setSecret("first", for: key)
        XCTAssertEqual(try store.secret(for: key), "first")
        try store.setSecret("second", for: key)
        XCTAssertEqual(try store.secret(for: key), "second")
        try store.setSecret(nil, for: key)
        XCTAssertNil(try store.secret(for: key))
        try store.setSecret(nil, for: key)
    }

    func testConfigurationStoreRequiresBothValues() throws {
        let secrets = InMemorySecretStore()
        let store = BankGatewayConfigurationStore(secretStore: secrets)

        XCTAssertNil(try store.load())
        let configuration = BankGatewayConfiguration(baseURL: URL(string: "https://gateway.test")!, bearerToken: "abc")
        try store.save(configuration)
        XCTAssertEqual(try store.load(), configuration)

        try secrets.setSecret("", for: "bankGateway.token")
        XCTAssertNil(try store.load())

        try store.save(configuration)
        try store.clear()
        XCTAssertNil(try store.load())
        XCTAssertNil(try secrets.secret(for: "bankGateway.baseURL"))
    }
}
