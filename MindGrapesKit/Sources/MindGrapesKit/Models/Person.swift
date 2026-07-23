// ABOUTME: A capture participant, always carrying a non-empty name.
// ABOUTME: The server silently skips nameless participant objects, so the name is an invariant.

import Foundation

/// A person attached to a capture.
///
/// SPEC 6.3: `people` is sent exclusively as a JSON array of objects, and the
/// server's resolver silently skips any object without a usable `name`. A
/// dropped participant is invisible to the user, so the failable initializer
/// makes a nameless `Person` unrepresentable instead of letting one reach the
/// wire.
public struct Person: Sendable, Hashable, Codable {
    public let name: String
    public let relationship: String?

    /// Returns `nil` when `name` is empty or whitespace only.
    public init?(name: String, relationship: String? = nil) {
        guard let name = name.nonBlank else { return nil }
        self.name = name
        self.relationship = relationship?.nonBlank
    }
}
