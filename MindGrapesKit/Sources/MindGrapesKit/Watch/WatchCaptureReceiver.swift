// ABOUTME: Turns a WCSession handoff into exactly one durable CaptureRecord on the phone.
// ABOUTME: Every decision the phone's session delegate makes lives here, where it is testable.

import Foundation

/// The phone's half of the watch relay (SPEC Decision 5, 8.1).
///
/// Deliberately knows nothing about `WCSession`. The delegate that owns the
/// session is a handful of unavoidable lines in the app target, which has no test
/// target (#24); everything it decides is here instead. Same split as
/// ``BackgroundUploadReconciler`` behind `BackgroundUploader`.
///
/// **Enqueue happens before the geocode, not after.** Once
/// `session(_:didReceiveUserInfo:)` returns, the system considers the transfer
/// delivered and will not hand it over again — so a process that died waiting on a
/// geocoder would lose the capture outright. Making the record durable first means
/// a hung geocoder costs the place label and nothing else.
public struct WatchCaptureReceiver: Sendable {
    /// What one handoff turned into, in terms a caller can log without this type
    /// knowing anything about logging.
    public enum Outcome: Sendable, Equatable {
        /// A new record exists under the Watch's own id.
        case enqueued(UUID)
        /// The Watch's id was already in the store, so nothing changed.
        /// `transferUserInfo` retries until the counterpart acknowledges, so this is
        /// expected traffic rather than a fault.
        case duplicate(UUID)
        /// The dictionary was not one of ours. `reason` is a short stable code, not
        /// a user string.
        case rejected(reason: String)
    }

    private let queue: CaptureQueue
    private let geocoder: (any ReverseGeocoding)?
    private let geocodeBudget: Duration

    /// - Parameters:
    ///   - queue: the outbox this capture joins, the same one every other entry
    ///     point uses.
    ///   - geocoder: turns the wrist's coordinate into a place label. `nil` when the
    ///     user's location toggle is off, in which case no label is attempted.
    ///   - geocodeBudget: ceiling on the label lookup. This runs inside a session
    ///     delivery callback that the system does not wait on indefinitely, so the
    ///     geocode is bounded rather than trusted.
    public init(
        queue: CaptureQueue,
        geocoder: (any ReverseGeocoding)? = nil,
        geocodeBudget: Duration = .seconds(3)
    ) {
        self.queue = queue
        self.geocoder = geocoder
        self.geocodeBudget = geocodeBudget
    }

    /// Enqueues one handoff, then labels it if it carried a coordinate.
    ///
    /// - Parameters:
    ///   - userInfo: the dictionary from `session(_:didReceiveUserInfo:)`.
    ///   - now: the record's `createdAt`. Never its `occurredAt`: that came from the
    ///     wrist and is the whole point of the payload (Phase 3 condition 1).
    @discardableResult
    public func receive(userInfo: [String: Any], now: Date = Date()) async -> Outcome {
        guard let payload = WatchCapturePayload(userInfo: userInfo) else {
            return .rejected(reason: "malformed_payload")
        }
        guard let draft = payload.noteDraft(placeLabel: nil) else {
            // Unreachable unless the payload's non-blank rule and the draft's
            // disagree, which would be a bug in one of them rather than bad input.
            return .rejected(reason: "empty")
        }

        let outcome: CaptureQueue.IdentifiedEnqueueOutcome
        do {
            outcome = try await queue.enqueue(note: draft, id: payload.id, now: now)
        } catch {
            return .rejected(reason: "save_failed")
        }

        guard outcome == .inserted else { return .duplicate(payload.id) }

        await attachLabelIfPossible(to: payload)
        return .enqueued(payload.id)
    }

    /// Best effort, and silent on every failure: SPEC 9 treats a missing label as
    /// normal and a geocode failure as non-fatal. A label that arrives after the
    /// first drain pass is dropped by ``CaptureQueue/attachPlaceLabel(id:label:)``,
    /// which is the correct outcome — the row must not disagree with what was sent.
    private func attachLabelIfPossible(to payload: WatchCapturePayload) async {
        guard let geocoder, let coordinate = payload.coordinate else { return }

        let label = await withTimeBudget(geocodeBudget) {
            await geocoder.placeLabel(for: coordinate)
        }
        guard let label else { return }

        try? await queue.attachPlaceLabel(id: payload.id, label: label)
    }
}
