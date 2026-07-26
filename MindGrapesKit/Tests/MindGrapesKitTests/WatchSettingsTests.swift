// ABOUTME: Proves the phone never tells the wrist to take a location the user has not agreed to.
// ABOUTME: The unanswered case is the whole point: the Watch cannot ask, so it must not be told yes.

import Foundation
import Testing

@testable import MindGrapesKit

@Suite
struct WatchSettingsTests {
    private func scratch() throws -> SharedDefaults {
        let name = "WatchSettingsTests.\(UUID().uuidString)"
        return SharedDefaults(defaults: try #require(UserDefaults(suiteName: name)))
    }

    /// The bug this exists for. `includeLocation` defaults to `true` when unset,
    /// which is right for the phone (it asks before it acts) and wrong for the
    /// wrist (it cannot ask). Pushing an unset `true` makes the watch app raise a
    /// system location alert the moment it opens, unprompted.
    @Test("An unanswered location pitch is pushed as no")
    func unansweredPitchIsNo() throws {
        let defaults = try scratch()
        #expect(defaults.includeLocation, "precondition: the phone's own default is yes")

        #expect(WatchSettings.includeLocation(defaults) == false)
    }

    @Test("An answered yes is pushed as yes")
    func answeredYesIsYes() throws {
        let defaults = try scratch()
        defaults.locationPitchAnswered = true
        defaults.includeLocation = true

        #expect(WatchSettings.includeLocation(defaults))
    }

    @Test("An answered no is pushed as no")
    func answeredNoIsNo() throws {
        let defaults = try scratch()
        defaults.locationPitchAnswered = true
        defaults.includeLocation = false

        #expect(WatchSettings.includeLocation(defaults) == false)
    }

    /// The conservative direction when the App Group cannot be opened at all.
    @Test("No shared store means no")
    func missingStoreIsNo() {
        #expect(WatchSettings.includeLocation(nil) == false)
    }

    /// Turning it back off after answering must reach the wrist as off, not fall
    /// back to the unset default of on.
    @Test("Turning location off after answering stays off")
    func revokedAnswerStaysOff() throws {
        let defaults = try scratch()
        defaults.locationPitchAnswered = true
        defaults.includeLocation = true
        #expect(WatchSettings.includeLocation(defaults))

        defaults.includeLocation = false

        #expect(WatchSettings.includeLocation(defaults) == false)
    }
}
