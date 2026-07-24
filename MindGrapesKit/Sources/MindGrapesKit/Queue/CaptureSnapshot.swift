// ABOUTME: The Sendable value the CaptureQueue hands out for one capture's queue state.
// ABOUTME: CaptureRecord is confined to the actor; callers see this copy instead.

import Foundation

/// A point-in-time copy of a ``CaptureRecord``'s identity and queue bookkeeping.
///
/// ``CaptureRecord`` is a SwiftData `@Model`, not `Sendable`, and is confined to
/// the ``CaptureQueue`` actor (see the type's own note). Everything outside the
/// actor, item 6's transport and item 18's status list included, reads this
/// value instead of touching the record.
///
/// ponytail: identity plus bookkeeping only. When item 6 builds a request from a
/// snapshot it will need the payload fields too; add them here then, additively.
public struct CaptureSnapshot: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let kind: CaptureKind
    public let state: CaptureState
    public let attemptCount: Int
    public let nextAttemptAt: Date
    public let lastErrorCode: String?
    public let experienceID: String?
    public let createdAt: Date

    init(_ record: CaptureRecord) {
        id = record.id
        kind = record.kind
        state = record.state
        attemptCount = record.attemptCount
        nextAttemptAt = record.nextAttemptAt
        lastErrorCode = record.lastErrorCode
        experienceID = record.experienceID
        createdAt = record.createdAt
    }

    /// The value sent as `idempotency_key` (SPEC 6.5).
    public var idempotencyKey: String { id.uuidString }
}
