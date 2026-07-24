// ABOUTME: Formats `occurred_at` for both capture doors as ISO 8601 with a numeric offset.
// ABOUTME: The server feeds the string to Postgres as ::timestamptz, so the spelling is a contract.

import Foundation

/// The one way a `Date` becomes an `occurred_at` string.
///
/// SPEC 6.3 asks for "ISO 8601 with a UTC offset" and shows
/// `2026-07-23T14:03:11-04:00`. Two spellings are deliberately avoided:
///
/// - `Z`, which `ISO8601DateFormatter` emits for a zero offset. It is legal
///   ISO 8601, but nothing has confirmed the server's parser accepts it, and a
///   device really can be in UTC.
/// - Fractional seconds, which would have to round somewhere and would make the
///   same record encode differently on a retry.
///
/// Components are read through a Gregorian calendar rather than a `DateFormatter`
/// so there is no locale to configure and no format string to misread.
enum WireTimestamp {
    static func string(from date: Date, in timeZone: TimeZone) -> String {
        // Truncate toward the past first: `dateComponents` would otherwise be
        // free to round a sub-second remainder up into the next second.
        let whole = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: whole)

        let stamp = String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0,
            parts.hour ?? 0,
            parts.minute ?? 0,
            parts.second ?? 0
        )

        // A zero offset reads as "+", which is what keeps UTC from spelling
        // itself `Z`. Sub-minute offsets exist only in pre-standardisation
        // historical zones, and ISO 8601's extended form has nowhere to put
        // them, so they round away here too.
        let offset = timeZone.secondsFromGMT(for: whole)
        let magnitude = abs(offset)
        let sign = offset < 0 ? "-" : "+"
        return stamp + sign + String(format: "%02d:%02d", magnitude / 3600, (magnitude % 3600) / 60)
    }
}
