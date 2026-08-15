// ABOUTME: Decides whether the Journaling Suggestions capture entry point can run here.
// ABOUTME: The picker never runs on Simulator, so the toolbar button hides there and shows on device.

/// Whether Apple's `JournalingSuggestionsPicker` can plausibly present on this
/// install, used to hide the capture-screen entry point when it cannot.
///
/// The picker requires both a real device and the
/// `com.apple.developer.journal.allow` entitlement, and there is no public
/// `isAvailable` boolean to ask. This check proves only the one thing it can
/// prove locally: the picker never functions on the Simulator, so the button
/// hides there. On a real device it returns `true` and trusts that a normally
/// signed build carries the entitlement — it does not inspect the entitlement
/// itself, so a misprovisioned device build would still show the button. A
/// device-only spike (issue #52, Phase 0) may later find a first-party signal to
/// replace this with; until then, absent-on-Simulator / present-on-device is the
/// behavior the acceptance criteria ask for and the safe direction (a hidden
/// button never strands the user in a broken picker).
enum JournalingSuggestionsAvailability {
    static var isSupported: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }
}
