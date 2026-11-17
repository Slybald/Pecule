import Foundation
import SwiftData

// Profile-local recovery metadata. Never persist the authorization URL or bank credentials.
@Model
final class BankPendingAuthorization {
    @Attribute(.unique) var key: String = "pending"
    var linkID: String
    var institution: String
    var requiresAccountSelection: Bool = false
    var expiresAt: Date

    init(linkID: String, institution: BankInstitution, expiresAt: Date) {
        self.linkID = linkID
        self.institution = institution.rawValue
        self.expiresAt = expiresAt
    }
}
