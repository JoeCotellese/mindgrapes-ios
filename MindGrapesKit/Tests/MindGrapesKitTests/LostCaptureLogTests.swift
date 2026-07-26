// ABOUTME: Proves a lost wrist capture is still reported after the watch app has been terminated.
// ABOUTME: The durability is the point: the final failure usually lands in a relaunch nobody is watching.

import Foundation
import Testing

@testable import MindGrapesKit

/// Each test gets its own suite-backed `UserDefaults` so nothing leaks between
/// them or into the host.
@Suite
struct LostCaptureLogTests {
    private func scratchDefaults() throws -> UserDefaults {
        let name = "LostCaptureLogTests.\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: name))
    }

    @Test("A fresh log has nothing to report")
    func startsEmpty() throws {
        let log = LostCaptureLog(defaults: try scratchDefaults())

        #expect(log.count == 0)
    }

    @Test("A recorded loss is counted")
    func recordsALoss() throws {
        let log = LostCaptureLog(defaults: try scratchDefaults())

        log.record(UUID())

        #expect(log.count == 1)
    }

    /// The reason this stores ids rather than an integer. `didFinish` can be
    /// delivered again for a transfer already given up on, and a count would
    /// climb every time.
    @Test("The same capture is never counted twice")
    func recordingIsIdempotent() throws {
        let log = LostCaptureLog(defaults: try scratchDefaults())
        let id = UUID()

        log.record(id)
        log.record(id)
        log.record(id)

        #expect(log.count == 1)
    }

    @Test("Separate captures are counted separately")
    func distinctLossesAccumulate() throws {
        let log = LostCaptureLog(defaults: try scratchDefaults())

        log.record(UUID())
        log.record(UUID())

        #expect(log.count == 2)
    }

    /// The whole reason this type exists. watchOS terminates the watch app on
    /// wrist-down, so the object that recorded the loss is usually gone by the
    /// time anyone looks at the screen. A second instance over the same storage
    /// stands in for the next launch.
    @Test("A loss recorded in one launch is still there in the next")
    func survivesProcessDeath() throws {
        let defaults = try scratchDefaults()
        let id = UUID()

        LostCaptureLog(defaults: defaults).record(id)

        #expect(LostCaptureLog(defaults: defaults).count == 1)
    }

    @Test("Clearing forgets every loss")
    func clearForgetsEverything() throws {
        let defaults = try scratchDefaults()
        let log = LostCaptureLog(defaults: defaults)
        log.record(UUID())
        log.record(UUID())

        log.clear()

        #expect(log.count == 0)
        #expect(LostCaptureLog(defaults: defaults).count == 0)
    }
}
