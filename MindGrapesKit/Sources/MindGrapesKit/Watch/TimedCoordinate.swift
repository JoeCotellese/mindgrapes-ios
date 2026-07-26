// ABOUTME: A coordinate with the time it was taken, so a stale one is never stamped on a capture.
// ABOUTME: The wrist pre-warms location before dictation; this decides when that fix has gone off.

import Foundation

/// A coordinate and the moment it was obtained.
///
/// The wrist starts a location request when the user opens the app or taps
/// Capture, so a fix is usually ready by the time dictation comes back
/// (`WatchCaptureRelay.beginCapture()`). Holding the bare coordinate is not
/// enough: nothing clears it when the input sheet is dismissed without
/// submitting, so a fix taken at one place survives in memory and gets stamped on
/// a capture made somewhere else entirely. A wrong location is worse than none,
/// because SPEC 9 already treats a missing one as normal.
public struct TimedCoordinate: Sendable, Equatable {
    public let coordinate: Coordinate
    public let takenAt: Date

    /// How long a fix is worth using.
    ///
    /// Two minutes because that is roughly the outer edge of "the user opened the
    /// app and then dictated": long enough to survive a slow dictation or a
    /// second thought, short enough that a walk to the next block invalidates it.
    public static let freshness: TimeInterval = 120

    public init(coordinate: Coordinate, takenAt: Date) {
        self.coordinate = coordinate
        self.takenAt = takenAt
    }

    /// The coordinate if it is still worth trusting at `now`, otherwise `nil`.
    ///
    /// A fix stamped in the future is treated as fresh rather than discarded: that
    /// is clock adjustment, not staleness, and throwing away a good fix over it
    /// would be the worse trade.
    public func coordinate(asOf now: Date) -> Coordinate? {
        let age = now.timeIntervalSince(takenAt)
        guard age <= Self.freshness else { return nil }
        return coordinate
    }
}
