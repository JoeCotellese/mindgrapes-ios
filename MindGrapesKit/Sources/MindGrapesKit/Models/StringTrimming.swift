// ABOUTME: Shared whitespace trimming used by every capture value type.
// ABOUTME: Kept in one place so "empty means absent" means the same thing everywhere.

import Foundation

extension String {
    /// The receiver with surrounding whitespace and newlines removed, or `nil`
    /// when nothing is left.
    ///
    /// The server trims string fields and treats empty as absent (SPEC 6.3), so
    /// the client normalizes at construction rather than letting a
    /// whitespace-only value travel as if it were content.
    var nonBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
