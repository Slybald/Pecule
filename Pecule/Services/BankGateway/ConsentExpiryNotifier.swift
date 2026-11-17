import Foundation
import UserNotifications

// One quiet reminder per linked account, seven days before its consent expires.
struct ConsentExpiryNotifier {
    static let leadDays = 7
    static let identifierPrefix = "consent-expiry-"
    static let deliveryHour = 9

    let calendar: Calendar
    let namespace: String?

    init(calendar: Calendar = .current, namespace: String? = nil) {
        self.calendar = calendar
        self.namespace = namespace
    }

    func requests(for accounts: [ExternalAccount], now: Date, locale: Locale = LocalizationManager.currentAppLocale) -> [UNNotificationRequest] {
        accounts.compactMap { account in
            guard !account.isManual,
                  let consentValidUntil = account.consentValidUntil,
                  let reminderDay = calendar.date(byAdding: .day, value: -Self.leadDays, to: consentValidUntil) else {
                return nil
            }
            var components = calendar.dateComponents([.year, .month, .day], from: reminderDay)
            components.hour = Self.deliveryHour
            guard let fireDate = calendar.date(from: components), fireDate > now else {
                return nil
            }
            let content = UNMutableNotificationContent()
            content.title = AppLocalizer.string("notification.consent.title", locale: locale)
            content.body = AppLocalizer.format("notification.consent.body %@ %@", locale: locale, account.name, Formatters.dateString(for: consentValidUntil))
            content.sound = nil
            return UNNotificationRequest(
                identifier: Self.identifierPrefix + (namespace.map { $0 + "-" } ?? "") + account.stableIdentifier,
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            )
        }
    }

    // Provisional authorization delivers quietly to Notification Center without a permission prompt.
    @MainActor
    func refresh(for accounts: [ExternalAccount], now: Date = Date(), isCurrent: @MainActor () -> Bool = { true }) async {
        // Resolve SwiftData properties before suspension; an account may be unlinked
        // while authorization or notification-center requests are in flight.
        let reminders = requests(for: accounts, now: now)
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .provisional])) == true else {
            return
        }
        guard isCurrent() else { return }
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.identifierPrefix) }
        guard isCurrent() else { return }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        for request in reminders {
            guard isCurrent(), !Task.isCancelled else { return }
            try? await center.add(request)
            if !isCurrent() { center.removePendingNotificationRequests(withIdentifiers: [request.identifier]); return }
        }
    }
}
