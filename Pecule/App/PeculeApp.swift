import SwiftUI
import SwiftData
import UIKit

@main
struct PeculeApp: App {
    @StateObject private var runtime: PeculeRuntime
    @StateObject private var localization = LocalizationManager()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let runtime = PeculeRuntime()
        _runtime = StateObject(wrappedValue: runtime)
        UIView.setAnimationsEnabled(!runtime.automation.disablesAnimations)
        AppHaptics.isEnabled = !runtime.automation.disablesAnimations
        BankBackgroundRefresh.register(appStateProvider: { [weak runtime] in runtime?.appState }, isEnabled: !runtime.automation.usesStubBankGateway)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let coordinator = runtime.coordinator {
                    IdentitySessionRoot(runtime: runtime, coordinator: coordinator)
                } else { RuntimeContent(runtime: runtime) }
            }
            .id(localization.locale.identifier)
            .onOpenURL { url in
                Task { await runtime.handleIncomingURL(url) }
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                guard let state = runtime.appState else { return }
                let backgroundEnabled = !runtime.automation.usesStubBankGateway
                if phase == .background { BankBackgroundRefresh.schedule(isEnabled: backgroundEnabled) }
                guard phase == .active else { return }
                state.reload()
                // Under the recovery screen nothing may refresh or notify on top of a store that failed to load.
                guard state.loadFailure == nil, state.isBankGatewayConfigured else { return }
                Task {
                    await state.bankSync.refreshIfStale(state.linkedExternalAccounts, maxAge: 3600)
                    if backgroundEnabled, state.isProfileActive {
                        await ConsentExpiryNotifier(namespace: state.notificationScope).refresh(for: state.externalAccounts, isCurrent: { state.isProfileActive })
                    }
                }
            }
            .overlay {
                if PrivacyShieldPolicy.shouldShow(scenePhase: scenePhase, automation: runtime.automation) {
                    PrivacyShieldView().transition(.opacity)
                }
            }
            .environmentObject(localization)
            .environment(\.locale, localization.locale)
        }
    }
}

private struct IdentitySessionRoot: View {
    @ObservedObject var runtime: PeculeRuntime
    @ObservedObject var coordinator: GatewaySessionCoordinator
    var body: some View {
        RuntimeContent(runtime: runtime)
            .task { await runtime.restore() }
            .onChange(of: coordinator.state) { _, state in runtime.sessionDidChange(state) }
    }
}

// The app itself, or the recovery screen when the store could not be read: never an empty app.
private struct LoadedRoot: View {
    @ObservedObject var state: AppState
    let container: ModelContainer

    var body: some View {
        if let failure = state.loadFailure {
            StoreRecoveryView(messageKey: "storage.recovery.message.loadFailed", identifier: failure.identifier) {
                state.reload()
                if state.loadFailure != nil { AppHaptics.play(.error) }
            }
        } else {
            RootTabView().modelContainer(container).environmentObject(state)
        }
    }
}

private struct RuntimeContent: View {
    @ObservedObject var runtime: PeculeRuntime
    @Environment(\.locale) private var locale
    var body: some View {
        Group {
            if let state = runtime.appState, let container = runtime.container {
                LoadedRoot(state: state, container: container).id(ObjectIdentifier(state))
            } else if let failure = runtime.storeFailure {
                StoreRecoveryView(failure: failure) {
                    runtime.retryOpeningStore()
                    // Si l'échec persiste, l'écran reste identique : le retour tactile dit que l'essai a bien eu lieu.
                    if runtime.storeFailure != nil { AppHaptics.play(.error) }
                }
            } else if runtime.gatewayURL != nil {
                NavigationStack {
                    VStack(spacing: AppSpacing.lg) {
                        Image(systemName: "leaf.fill").font(.system(size: 56)).foregroundStyle(AppColors.accent)
                        Text(AppLocalizer.string("identity.welcome", locale: locale)).font(AppTypography.cardTitle)
                        Text(AppLocalizer.string("identity.explanation", locale: locale)).multilineTextAlignment(.center)
                        Button { Task { await runtime.signIn() } } label: {
                            Label(AppLocalizer.string("identity.signIn", locale: locale), systemImage: "apple.logo")
                        }.buttonStyle(.borderedProminent).accessibilityIdentifier("identity-sign-in")
                        Button(AppLocalizer.string("identity.manual", locale: locale)) { runtime.openManualProfile() }
                            .accessibilityIdentifier("identity-manual")
                        if runtime.isBusy { ProgressView() }
                        if let error = runtime.errorMessage { Text(error).foregroundStyle(AppColors.error) }
                    }.padding(AppSpacing.xl).disabled(runtime.isBusy)
                }
            } else {
                ContentUnavailableView(AppLocalizer.string("storage.unavailable", locale: locale), systemImage: "externaldrive.badge.exclamationmark", description: Text(runtime.errorMessage ?? ""))
            }
        }
    }
}
