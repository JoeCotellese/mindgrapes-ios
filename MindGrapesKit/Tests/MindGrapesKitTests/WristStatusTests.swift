// ABOUTME: Proves the wrist can never report a delivery, and never reports failure as success.
// ABOUTME: SPEC 10.8's honesty constraint expressed as assertions rather than as a convention.

import Testing

@testable import MindGrapesKit

/// The status line is the whole honesty mechanism of the watch app, so the rule
/// that produces it is tested here rather than trusted in a view.
@Suite
struct WristStatusTests {
    @Test("Nothing outstanding and nothing failed means the phone took everything")
    func emptyOutboxIsWithPhone() {
        #expect(WristStatus.derive(outstanding: 0, failed: 0) == .withPhone)
    }

    @Test("One outstanding transfer is one capture waiting")
    func oneOutstandingIsWaiting() {
        #expect(WristStatus.derive(outstanding: 1, failed: 0) == .waiting(count: 1, phoneNearby: true))
    }

    /// The bug the first prototype had, as a test. It assigned status from whoever
    /// finished last, so with two captures outstanding the first completion
    /// announced "With the phone" while the second was still in the outbox: the
    /// wrist claiming a handoff that had not happened.
    @Test("A second outstanding transfer is still waiting, not with the phone")
    func twoOutstandingIsNeverWithPhone() {
        let status = WristStatus.derive(outstanding: 2, failed: 0)
        #expect(status == .waiting(count: 2, phoneNearby: true))
        #expect(status != .withPhone)
    }

    /// The honesty constraint, from the direction that is easy to miss. A transfer
    /// that finishes *with an error* is removed from
    /// `WCSession.outstandingUserInfoTransfers` exactly like a successful one, so a
    /// status derived from list emptiness alone reports failure as success.
    @Test("A failed transfer is never reported as with the phone")
    func failureIsNeverWithPhone() {
        let status = WristStatus.derive(outstanding: 0, failed: 1)
        #expect(status == .failed(count: 1))
        #expect(status != .withPhone)
    }

    /// A failure outranks a pending transfer because it is the only one of the two
    /// the user can act on: the pending one needs nothing but patience.
    @Test("A failure outranks a still-pending transfer")
    func failureOutranksWaiting() {
        #expect(WristStatus.derive(outstanding: 1, failed: 1) == .failed(count: 1))
    }

    @Test("Counts are carried through so the line can say how many")
    func countsAreCarried() {
        #expect(WristStatus.derive(outstanding: 3, failed: 0) == .waiting(count: 3, phoneNearby: true))
        #expect(WristStatus.derive(outstanding: 0, failed: 2) == .failed(count: 2))
    }

    /// Reachability is a fact the wrist legitimately has, and "waiting" means
    /// something different in each case: seconds away versus hours away.
    @Test("Waiting carries whether the phone is nearby")
    func waitingCarriesReachability() {
        #expect(
            WristStatus.derive(outstanding: 1, failed: 0, phoneNearby: false)
                == .waiting(count: 1, phoneNearby: false)
        )
    }

    /// The one state where nothing will ever arrive no matter how long the user
    /// waits, so it outranks everything: the phone app is gone.
    @Test("A missing counterpart app outranks every other state")
    func missingCounterpartOutranksEverything() {
        #expect(
            WristStatus.derive(outstanding: 0, failed: 0, companionAppInstalled: false)
                == .companionAppMissing
        )
        #expect(
            WristStatus.derive(outstanding: 2, failed: 1, companionAppInstalled: false)
                == .companionAppMissing
        )
    }

    /// Negative input cannot come from `outstandingUserInfoTransfers.count`, but a
    /// hand-maintained failure counter that double-decrements could produce it, and
    /// `.waiting(count: -1)` would render "-1 waiting for the phone".
    @Test("Nonsense counts clamp rather than render")
    func negativeCountsClamp() {
        #expect(WristStatus.derive(outstanding: -1, failed: 0) == .withPhone)
        #expect(WristStatus.derive(outstanding: 0, failed: -1) == .withPhone)
    }
}
