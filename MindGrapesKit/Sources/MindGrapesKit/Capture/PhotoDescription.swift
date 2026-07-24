// ABOUTME: The fallback description a photo carries when the user types none (SPEC 7.3 template path).
// ABOUTME: Kept tiny and testable so Slice 2's screen and Slice 4's photo intent share one wording.

import Foundation

/// The client-side description of last resort.
///
/// ``PhotoDraft`` requires a non-blank description because that is the switch
/// keeping photo bytes on the household's own server (SPEC 11): a `shared`
/// capture with no description triggers the server's off-box vision fallback.
/// Slices 2 and 4 have no OCR or on-device model yet (that is Slice 6), so when
/// the user supplies no words this composes a usable one from the timestamp.
///
/// ponytail: timestamp only. Slice 6 replaces this with the real OCR + model
/// description; keep it dumb so that swap is clean.
public enum PhotoDescription {
    /// A non-empty description naming when the photo was taken.
    public static func template(occurredAt: Date, timeZone: TimeZone = .current) -> String {
        "Photo captured \(WireTimestamp.string(from: occurredAt, in: timeZone))"
    }
}
