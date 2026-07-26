// ABOUTME: Decides what the phone tells the wrist about location, from the phone's own stored answer.
// ABOUTME: The wrist must never prompt for a permission the user has not been asked about (SPEC 9).

import Foundation

/// What the phone pushes to the Watch with `updateApplicationContext`.
///
/// A rule rather than a direct read, because the direct read is wrong in one
/// specific and damaging way. ``SharedDefaults/includeLocation`` defaults to
/// `true` when nothing has been stored, which is the right default for the phone:
/// the phone asks before it acts. The Watch has no way to ask. Pushing an unset
/// `true` makes the wrist call `requestWhenInUseAuthorization()` the moment its
/// app opens, so a user who has not finished onboarding gets a system location
/// alert on their watch having touched nothing — the exact prompt SPEC 9 forbids.
///
/// Lives in the kit because the watch target and the phone's session coordinator
/// both have no test target (#24), and this is the decision that keeps an
/// unsolicited permission prompt off a wrist.
public enum WatchSettings {
    /// Whether the wrist should take a location fix.
    ///
    /// `false` until the user has actually answered the location pitch, and
    /// `false` when the shared store is unavailable. Both are the conservative
    /// direction: a capture with no coordinate is a whole capture (SPEC 9), and a
    /// prompt the user never invited is not recoverable.
    public static func includeLocation(_ defaults: SharedDefaults?) -> Bool {
        guard let defaults, defaults.locationPitchAnswered else { return false }
        return defaults.includeLocation
    }
}
