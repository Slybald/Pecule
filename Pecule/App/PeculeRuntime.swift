import SwiftUI
import SwiftData
import UserNotifications

// Replacing a profile replaces the entire model container and all derived state.
@MainActor
final class PeculeRuntime: ObservableObject {
    @Published private(set) var appState: AppState?
    @Published private(set) var container: ModelContainer?
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?
    // Renseigné quand la base sur disque ne s'ouvre pas : l'écran de reprise remplace alors l'app. La base
    // n'a été ni supprimée, ni recréée, ni remplacée par une base vide ou en mémoire.
    @Published private(set) var storeFailure: StoreOpenError?
    let automation: AppAutomationConfiguration
    let gatewayURL: URL?
    let coordinator: GatewaySessionCoordinator?
    private var epoch: UInt64 = 0
    private var incomingBankURL: URL?
    private let legacyContainerFactory: (() throws -> ModelContainer)?
    private var hasSimulatedStoreFailure = false
    // L'ouverture à refaire quand l'utilisateur touche « Réessayer ».
    private var pendingStoreOpen: PendingStoreOpen?

    private enum PendingStoreOpen {
        case legacy
        case profile(userID: String, manual: Bool)
    }

    static var configuredIdentityURL: URL? {
        identityURL(from: Bundle.main.object(forInfoDictionaryKey: "PeculeIdentityGatewayURL") as? String)
    }

    // Seul https est accepté : un jeton d'identité ne part jamais en clair.
    static func identityURL(from raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw), url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    // `makeLegacyContainer` ne sert qu'aux tests : il remplace l'ouverture de la base historique.
    init(
        automation: AppAutomationConfiguration = .current,
        gatewayURL: URL? = PeculeRuntime.configuredIdentityURL,
        makeLegacyContainer: (() throws -> ModelContainer)? = nil
    ) {
        self.automation = automation
        // Every automated launch starts with the developer mode off, whatever a previous test left on this simulator.
        if automation.dataMode != nil { UserDefaults.standard.removeObject(forKey: DeveloperMode.key) }
        self.legacyContainerFactory = makeLegacyContainer
        self.gatewayURL = automation.usesStubBankGateway ? nil : gatewayURL
        if let url = self.gatewayURL {
            coordinator = GatewaySessionCoordinator(authClient: LiveGatewayAuthClient(baseURLProvider: { url }), issuerProvider: { url })
        } else { coordinator = nil }
        AppIntentSupport.requiresActiveProfile = self.gatewayURL != nil
        if coordinator == nil { openLegacyStore() }
    }

    func restore() async {
        guard appState == nil, let coordinator else { return }
        isBusy = true
        defer { isBusy = false }
        coordinator.restore()
        guard coordinator.isSignedIn else { return }
        do {
            try await coordinator.validateRestoredSession()
            if let userID = coordinator.state.userId { try openProfile(userID: userID) }
        } catch {
            errorMessage = error.userMessage
        }
    }

    func signIn() async {
        guard let coordinator, !isBusy else { return }
        let startEpoch = epoch
        isBusy = true
        defer { isBusy = false }
        let apple = AppleSignInProvider()
        do {
            let userID = try await coordinator.signIn { try await apple.identityToken(for: $0) }
            guard epoch == startEpoch else { return }
            try openProfile(userID: userID)
        } catch is CancellationError {} catch { errorMessage = error.userMessage }
    }

    func openManualProfile() {
        do { try openProfile(userID: "local-manual", manual: true) }
        catch { errorMessage = error.userMessage }
    }

    // « Réessayer » de l'écran de reprise. Rouvre exactement ce qui a échoué ; si l'échec persiste,
    // l'écran reste, avec le même identifiant d'erreur.
    func retryOpeningStore() {
        guard let pending = pendingStoreOpen else { return }
        switch pending {
        case .legacy:
            openLegacyStore()
        case let .profile(userID, manual):
            // La session a pu se terminer pendant que l'écran de reprise était affiché : pas question de
            // rouvrir la base d'un profil dont personne n'est plus connecté.
            guard manual || coordinator?.isSignedIn == true else {
                storeFailure = nil
                pendingStoreOpen = nil
                return
            }
            do { try openProfile(userID: userID, manual: manual) }
            catch { errorMessage = error.userMessage }
        }
    }

    func signOut() async {
        epoch &+= 1
        incomingBankURL = nil
        closeProfile()
        await coordinator?.signOut()
    }

    func handleIncomingURL(_ url: URL) async {
        guard BankLinkCallback(url: url) != nil else { return }
        guard let state = appState else {
            incomingBankURL = url
            return
        }
        await state.bankSync.handleIncomingURL(url)
    }

    func sessionDidChange(_ state: GatewaySessionCoordinator.State) {
        if state == .signedOut, appState?.managesIdentity == true { closeProfile() }
    }

    private func makeLegacyContainer() throws -> ModelContainer {
        if let legacyContainerFactory { return try legacyContainerFactory() }
        if automation.simulatesStoreFailure, !hasSimulatedStoreFailure {
            hasSimulatedStoreFailure = true
            throw StoreOpenError(stage: .open, underlying: CocoaError(.fileReadCorruptFile), backup: URL(fileURLWithPath: "/dev/null"))
        }
        return try automation.usesInMemoryStore ? PeculeDataStore.makeInMemoryContainer() : PeculeDataStore.makeSharedContainer()
    }

    private func openLegacyStore() {
        do {
            let container = try makeLegacyContainer()
            let configuration = automation.usesStubBankGateway ? BankGatewayConfigurationStore(secretStore: InMemorySecretStore()) : BankGatewayConfigurationStore()
            let gateway: any BankGatewayClient = automation.usesStubBankGateway
                ? StubBankGatewayClient(stressesFinancialHealth: automation.usesInMemoryStore && automation.dataMode == .bankStress)
                : LiveBankGatewayClient(configurationProvider: { try configuration.load() })
            install(AppState(dataStore: PeculeDataStore(container: container), shouldSeedOnReload: automation.shouldSeedOnReload, bankGateway: gateway, bankGatewayConfigurationStore: configuration), container: container)
        } catch let failure as StoreOpenError {
            // Ni plantage, ni base de secours en mémoire, ni recréation : l'écran de reprise, et c'est tout.
            storeFailure = failure
            pendingStoreOpen = .legacy
        } catch { errorMessage = error.userMessage }
    }

    private func openProfile(userID: String, manual: Bool = false) throws {
        guard let issuer = gatewayURL else { throw GatewayAuthError.notConfigured }
        let location = ProfileStoreLocation(issuer: issuer, userID: userID)
        let container: ModelContainer
        do { container = try PeculeDataStore.makeProfileContainer(location: location) }
        catch let failure as StoreOpenError {
            // Le profil actuel, s'il y en a un, reste en place : `closeProfile()` n'est appelé qu'après une ouverture réussie.
            storeFailure = failure
            pendingStoreOpen = .profile(userID: userID, manual: manual)
            return
        }
        let gateway: any BankGatewayClient
        if !manual, let coordinator { gateway = SessionBankGatewayClient(coordinator: coordinator) }
        else { gateway = OfflineBankGatewayClient() }
        let state = AppState(dataStore: PeculeDataStore(container: container), preferenceKey: location.preferenceKey, bankGateway: gateway)
        state.managesIdentity = !manual
        state.identityGatewayURL = issuer
        state.requestSignOut = { [weak self] in await self?.signOut() }
        closeProfile()
        install(state, container: container)
    }

    private func install(_ state: AppState, container: ModelContainer) {
        storeFailure = nil
        pendingStoreOpen = nil
        self.container = container
        appState = state
        AppIntentSupport.dataStore = state.dataStore
        if let url = incomingBankURL {
            incomingBankURL = nil
            // The profile's persisted link ID must match before this callback can do anything.
            Task { await state.bankSync.handleIncomingURL(url) }
        }
    }

    private func closeProfile() {
        appState?.invalidateProfile()
        appState = nil
        container = nil
        // Un échec d'ouverture appartient au profil qu'on quitte : l'écran de reprise ne lui survit pas.
        storeFailure = nil
        pendingStoreOpen = nil
        AppIntentSupport.dataStore = nil
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()

    }
}
