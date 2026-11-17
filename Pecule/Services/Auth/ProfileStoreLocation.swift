import CryptoKit
import Foundation
import SwiftData

struct ProfileStoreLocation: Equatable, Sendable {
    let key: String
    init(issuer: URL, userID: String) {
        let identity = GatewaySessionStore.canonicalIssuer(issuer) + "\u{0}" + userID
        key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func storeURL(root: URL) -> URL {
        root.appending(path: "LifeOSProfiles", directoryHint: .isDirectory)
            .appending(path: key, directoryHint: .isDirectory).appending(path: "LifeOS.store")
    }
    var preferenceKey: String { "LifeOS.prefersBankAmounts." + key }
}

extension PeculeDataStore {
    // Les copies avant migration vivent à côté de la base, dans `LifeOSProfiles/<clé>/Backups` : chaque
    // profil a les siennes, et la limite de trois copies s'applique à lui seul.
    static func makeProfileContainer(location: ProfileStoreLocation, root: URL? = nil, opener: PersistentStoreOpener = PersistentStoreOpener()) throws -> ModelContainer {
        let url: URL
        do {
            let root = try root ?? opener.fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            url = location.storeURL(root: root)
            try opener.fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch { throw StoreOpenError(stage: .open, underlying: error, backup: nil) }
        let schema = PeculeSchema.current
        return try opener.open(ModelConfiguration("LifeOS", schema: schema, url: url))
    }
}
