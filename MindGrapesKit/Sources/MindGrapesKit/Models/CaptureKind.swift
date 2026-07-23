// ABOUTME: The two capture shapes and the queue states a capture moves through.
// ABOUTME: Raw values are persisted, so they are part of the on-disk contract.

import Foundation

/// Which capture door a record belongs to (SPEC 8.1).
public enum CaptureKind: String, Sendable, Codable, CaseIterable {
    case note
    case photo
}

/// Where a record sits in the outbox (SPEC 8.1, 8.3, 8.5).
///
/// `authRequired` is deliberately distinct from `failed`: a refresh that fails
/// with `invalid_grant` parks pending records rather than losing them, and a
/// successful re-auth revives them (SPEC 8.5).
public enum CaptureState: String, Sendable, Codable, CaseIterable {
    case pending
    case inFlight
    case succeeded
    case failed
    case authRequired
}
