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

    enum CodingKeys: String, CodingKey {
        case name
        case relationship
    }

    /// Decoding runs the same validation and trimming as the initializer.
    ///
    /// The synthesized `init(from:)` would assign `name` straight through, and
    /// this is not a hypothetical door: SwiftData persists `[Person]` as a
    /// Codable composite attribute, so every read from the capture store comes
    /// back this way. Without the check the invariant would hold at capture
    /// time and evaporate on the next launch.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)
        guard let person = Person(
            name: name,
            relationship: try container.decodeIfPresent(String.self, forKey: .relationship)
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .name,
                in: container,
                debugDescription: "A person's name cannot be empty or whitespace only."
            )
        }
        self = person
    }
}
