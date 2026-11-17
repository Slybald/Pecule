import BackgroundTasks
import Foundation

// Periodic sync while the app sleeps: at most three unattended fetches per account and per day, as the banks allow.
enum BankRefreshPolicy {
    static let taskIdentifier = "com.nicolas.LifeOS.bankRefresh"
    static let minimumInterval: TimeInterval = 8 * 3600
    static let staleAfter: TimeInterval = 8 * 3600
}

@MainActor
enum BankBackgroundRefresh {
    // Must run before the app finishes launching; automation runs never register (no real bank, no scheduler noise).
    static func register(appState: AppState, isEnabled: Bool) {
        register(appStateProvider: { appState }, isEnabled: isEnabled)
    }

    static func register(appStateProvider: @escaping @MainActor () -> AppState?, isEnabled: Bool) {
        guard isEnabled else {
            return
        }
        // nil uses a background queue; this callback belongs to MainActor just like AppState.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: BankRefreshPolicy.taskIdentifier, using: .main) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                guard let appState = appStateProvider() else { refreshTask.setTaskCompleted(success: true); return }
                handle(refreshTask, appState: appState)
            }
        }
    }

    static func schedule(isEnabled: Bool) {
        guard isEnabled else {
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: BankRefreshPolicy.taskIdentifier)
        request.earliestBeginDate = Date().addingTimeInterval(BankRefreshPolicy.minimumInterval)
        // Submitting again replaces the pending request; a refusal (simulator, low power) is not an error worth surfacing.
        try? BGTaskScheduler.shared.submit(request)
    }

    static func handle(_ task: BGAppRefreshTask, appState: AppState) {
        schedule(isEnabled: true)
        let work = Task { @MainActor in
            guard appState.isBankGatewayConfigured else {
                task.setTaskCompleted(success: true)
                return
            }
            await appState.bankSync.refreshIfStale(appState.linkedExternalAccounts, maxAge: BankRefreshPolicy.staleAfter, attended: false)
            await ConsentExpiryNotifier(namespace: appState.notificationScope).refresh(for: appState.externalAccounts, isCurrent: { appState.isProfileActive })
            task.setTaskCompleted(success: !Task.isCancelled)
        }
        task.expirationHandler = cancellationHandler(for: work)
    }

    // The scheduler may expire a task on any queue. Do not inherit MainActor here.
    nonisolated static func cancellationHandler(for work: Task<Void, Never>) -> @Sendable () -> Void {
        { work.cancel() }
    }
}
