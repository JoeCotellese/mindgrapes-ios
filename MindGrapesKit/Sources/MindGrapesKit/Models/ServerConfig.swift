// ABOUTME: The user-configured Mind Grapes server this install talks to.
// ABOUTME: Just the base URL; nothing about a particular host is baked into the binary.

import Foundation

/// The server a device is onboarded to.
///
/// The base URL is configured at runtime (README, SPEC 6), which is why it is a
/// stored value rather than a constant. Normalizing user input into one of
/// these is discovery's job, not this type's.
public struct ServerConfig: Sendable, Hashable, Codable {
    public let baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }
}
