import Foundation

extension Notification.Name {
    // Posted by App Intents after writing, so the running UI reloads its arrays.
    static let peculeDataDidChangeExternally = Notification.Name("Pecule.dataDidChangeExternally")
}

@MainActor
enum AppIntentSupport {
    // The running app registers its store so intents write exactly where the UI reads.
    static var dataStore: PeculeDataStore?
    static var requiresActiveProfile = false

    static func store() throws -> PeculeDataStore {
        if let dataStore {
            return dataStore
        }
        guard !requiresActiveProfile, PeculeRuntime.configuredIdentityURL == nil else { throw GatewaySessionCoordinator.SessionError.signedOut }
        let store = PeculeDataStore(container: try PeculeDataStore.makeSharedContainer())
        dataStore = store
        return store
    }

    static func notifyChange() {
        NotificationCenter.default.post(name: .peculeDataDidChangeExternally, object: nil)
    }
}
