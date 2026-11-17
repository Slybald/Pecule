import Foundation
import Security
import Synchronization

protocol SecretStore: Sendable {
    func secret(for key: String) throws -> String?
    func setSecret(_ value: String?, for key: String) throws
}

enum SecretStoreError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case invalidData
}

final class KeychainSecretStore: SecretStore {
    private let service: String

    init(service: String = "com.nicolas.LifeOS.bank-gateway") {
        self.service = service
    }

    func secret(for key: String) throws -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
                throw SecretStoreError.invalidData
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw SecretStoreError.unexpectedStatus(status)
        }
    }

    func setSecret(_ value: String?, for key: String) throws {
        guard let value else {
            let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw SecretStoreError.unexpectedStatus(status)
            }
            return
        }

        let data = Data(value.utf8)
        let updateStatus = SecItemUpdate(
            baseQuery(for: key) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw SecretStoreError.unexpectedStatus(updateStatus)
        }

        var attributes = baseQuery(for: key)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw SecretStoreError.unexpectedStatus(addStatus)
        }
    }

    private func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}

final class InMemorySecretStore: SecretStore {
    private let storage = Mutex<[String: String]>([:])

    init(initialValues: [String: String] = [:]) {
        storage.withLock { $0 = initialValues }
    }

    func secret(for key: String) throws -> String? {
        storage.withLock { $0[key] }
    }

    func setSecret(_ value: String?, for key: String) throws {
        storage.withLock { $0[key] = value }
    }
}
