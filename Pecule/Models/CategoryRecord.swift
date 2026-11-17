import Foundation
import SwiftData

// Stable key derived from the immutable canonical name. Renaming is intentionally not offered.
// Historical strings remain intact in existing records; their canonical key resolves this catalog.
@Model
final class CategoryRecord {
    @Attribute(.unique) var key: String
    var name: String
    init(name: String) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.key = ExpenseCategory.canonicalKey(for: name)
    }
}
