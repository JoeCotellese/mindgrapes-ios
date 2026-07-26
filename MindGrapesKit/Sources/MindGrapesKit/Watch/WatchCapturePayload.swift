// ABOUTME: One watch capture, in the property-list dictionary WCSession.transferUserInfo carries.
// ABOUTME: Stamped on the wrist so the phone records when the user spoke, not when it caught up.

import Foundation

/// A capture taken on the wrist, on its way to the phone (SPEC Decision 5).
///
/// Hand-converted to and from `[String: Any]` rather than encoded, because
/// `WCSession.transferUserInfo` takes a property list and not `Data`. Anything in
/// the dictionary that is not a property-list type makes `transferUserInfo` raise
/// at runtime rather than return an error, so ``userInfo`` is deliberately built
/// from `String`, `Date`, and `Double` only.
///
/// **The identity is stamped on the wrist, not on receipt.** `id` doubles as the
/// `idempotency_key` (SPEC 6.5), so a transfer the system redelivers enqueues the
/// same key rather than a second capture. `occurredAt` is when the user spoke; a
/// phone that defaulted it to `Date()` would record when it caught up, which for a
/// capture made on a run is simply the wrong time. Neither field is optional and
/// neither is defaulted, so a dictionary missing one is refused rather than
/// quietly filled in.
///
/// No `placeLabel`. The wrist takes the coordinate and the phone reverse-geocodes
/// it: `CLGeocoder` needs network, and a Watch with no phone nearby is exactly a
/// Watch with no network, so geocoding on the wrist would burn the whole budget to
/// return `nil` on the one case that matters (SPEC 9, and the design decision
/// recorded on #22).
public struct WatchCapturePayload: Sendable, Equatable {
    public let id: UUID
    public let content: String
    public let occurredAt: Date
    public let coordinate: Coordinate?

    private enum Key {
        static let id = "id"
        static let content = "content"
        static let occurredAt = "occurredAt"
        static let latitude = "latitude"
        static let longitude = "longitude"
    }

    /// Returns `nil` when `content` is empty or whitespace only, matching
    /// ``NoteDraft``: an empty capture never becomes a transfer.
    public init?(id: UUID, content: String, occurredAt: Date, coordinate: Coordinate?) {
        guard let content = content.nonBlank else { return nil }
        self.id = id
        self.content = content
        self.occurredAt = occurredAt
        self.coordinate = coordinate
    }

    /// The dictionary handed to `transferUserInfo`.
    public var userInfo: [String: Any] {
        var userInfo: [String: Any] = [
            Key.id: id.uuidString,
            Key.content: content,
            Key.occurredAt: occurredAt,
        ]
        if let coordinate {
            userInfo[Key.latitude] = coordinate.latitude
            userInfo[Key.longitude] = coordinate.longitude
        }
        return userInfo
    }

    /// Rebuilds a payload from a received dictionary, or returns `nil` if it is not
    /// one of ours.
    ///
    /// Two different failure policies here, on purpose:
    ///
    /// - A bad `id`, `content`, or `occurredAt` refuses the whole payload. Those
    ///   three are the capture; without any of them there is nothing to enqueue.
    /// - A bad coordinate drops only the coordinate. A capture with no location is
    ///   a whole capture (SPEC 9 treats a missing fix as normal), so losing the text
    ///   over a malformed number would be the worse trade.
    ///
    /// Unknown keys are ignored, because watchOS and iOS update independently and a
    /// newer wrist will eventually hand an older phone a key it has never heard of.
    public init?(userInfo: [String: Any]) {
        guard let rawID = userInfo[Key.id] as? String,
              let id = UUID(uuidString: rawID),
              let content = userInfo[Key.content] as? String,
              let occurredAt = userInfo[Key.occurredAt] as? Date
        else { return nil }

        // Both-or-neither: `Coordinate`'s initializer is the range check, and a
        // dictionary carrying one half of a pair yields no coordinate at all.
        let coordinate: Coordinate? =
            if let latitude = userInfo[Key.latitude] as? Double,
               let longitude = userInfo[Key.longitude] as? Double {
                Coordinate(latitude: latitude, longitude: longitude)
            } else {
                nil
            }

        self.init(id: id, content: content, occurredAt: occurredAt, coordinate: coordinate)
    }

    /// The note this becomes on the phone, with the label the phone supplied.
    ///
    /// The draft's own initializer is failable on blank content; this payload
    /// already guaranteed non-blank, so a `nil` here would be a bug in one of the
    /// two rules rather than bad input.
    public func noteDraft(placeLabel: String?) -> NoteDraft? {
        NoteDraft(
            content: content,
            occurredAt: occurredAt,
            coordinate: coordinate,
            placeLabel: placeLabel
        )
    }
}
