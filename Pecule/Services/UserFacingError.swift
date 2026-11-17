import Foundation
import SwiftData

// What the person is allowed to do about an error. The alert offers the button, the view decides where it leads.
enum UserFacingErrorAction: Equatable, Sendable {
    case none
    case reconnectBank
}

// The only place that turns a technical error into a sentence for the screen. Raw `localizedDescription`
// ("The operation couldn't be completed…", "404 ACCOUNT_DOES_NOT_EXIST") never reaches the interface: the cause
// goes to the log (`AppLog`), the screen gets a message and, when one exists, an action.
struct UserFacingError: Equatable, Sendable {
    let message: String
    let action: UserFacingErrorAction
    // Catalogue key behind `message`, nil for an app error that brings its own sentence. Stored instead of the text so that
    // a failure recorded in French still reads in English later (see BankFreshnessService.localizedStoredError).
    let key: String?

    init(_ error: Error, locale: Locale = LocalizationManager.currentAppLocale) {
        self = Self.resolve(error, locale: locale)
    }

    private init(_ message: String, _ action: UserFacingErrorAction = .none, key: String? = nil) {
        self.message = message
        self.action = action
        self.key = key
    }

    private static func resolve(_ error: Error, locale: Locale) -> UserFacingError {
        func text(_ key: String) -> String { AppLocalizer.string(key, locale: locale) }
        func known(_ key: String, _ action: UserFacingErrorAction = .none) -> UserFacingError {
            UserFacingError(text(key), action, key: key)
        }
        switch error {
        case let error as BankGatewayError:
            switch error {
            case .notConfigured: return known("bank.error.notConfigured")
            case .unauthorized: return known("bank.error.unauthorized")
            case .sessionExpired: return known("error.bank.linkExpired", .reconnectBank)
            case .rateLimited: return known("bank.error.rateLimited")
            case .linkNotFound: return known("bank.error.linkNotAuthorized")
            case .transport: return known("error.network")
            case .upstream(let status, let code): return upstream(status: status, code: code, known: known)
            case .http, .decoding: return known("error.bank.unexpected")
            }
        case let error as BankLinkError:
            switch error {
            case .incompleteImport: return known("bank.error.partialImport")
            case .refused(let code):
                AppLog.bank.error("Bank link refused: \(code, privacy: .private)")
                return known("bank.error.linkFailed")
            case .cancelled, .invalidCallback, .notAuthorized: return known("bank.error.linkNotAuthorized")
            }
        case let error as GatewaySessionCoordinator.SessionError:
            switch error {
            case .signedOut: return known("error.session.signedOut")
            case .expired: return known("auth.error.unauthorized")
            case .sessionChanged: return known("error.session.changed")
            }
        case is BankGatewayConfigurationError:
            return known("bank.error.notConfigured")
        case is URLError:
            return known("error.network")
        case is SwiftDataError:
            return known("error.data")
        default:
            if (error as NSError).domain == NSCocoaErrorDomain {
                return known("error.data")
            }
            // The app's own errors (allocation, commitments, store opening…) already carry a written sentence.
            if let described = (error as? LocalizedError)?.errorDescription {
                return UserFacingError(described)
            }
            return known("error.generic")
        }
    }

    // Enable Banking answers 404 when the account or the session behind a link no longer exists on the bank side:
    // the only way out is a new authorization. A session revoked or closed by the bank is the same case.
    private static func upstream(status: Int, code: String, known: (String, UserFacingErrorAction) -> UserFacingError) -> UserFacingError {
        let upper = code.uppercased()
        if status == 404 || upper.contains("EXPIRED") || upper.contains("REVOKED") || upper.contains("CLOSED") || upper.contains("DOES_NOT_EXIST") {
            return known("error.bank.linkExpired", .reconnectBank)
        }
        if status == 429 { return known("bank.error.rateLimited", .none) }
        if status >= 500 { return known("error.bank.unavailable", .none) }
        return known("error.bank.unexpected", .none)
    }
}

extension Error {
    // What a view shows. The cause goes to the log: the screen only gets the sentence.
    var userMessage: String {
        AppLog.ui.error("Error shown to the user: \(String(reflecting: type(of: self)), privacy: .public) \(String(describing: self), privacy: .private)")
        return UserFacingError(self).message
    }

    // Same sentence without the log line: for a `body` that is evaluated at every render, where the error already happened.
    var userMessageQuiet: String { UserFacingError(self).message }
}
