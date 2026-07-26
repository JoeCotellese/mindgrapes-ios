// ABOUTME: Proves the wrist can never report a delivery, and never reports failure as success.
// ABOUTME: SPEC 10.8's honesty constraint expressed as assertions rather than as a convention.

import Testing

@testable import MindGrapesKit

/// The status line is the whole honesty mechanism of the watch app, so the rule
/// that produces it is tested here rather than trusted in a view.
@Suite
struct WristStatusTests {
    /// The bug this test was rewritten for (#28). "Nothing outstanding" was being
    /// asked to mean both "nothing ever happened" and "everything arrived", and it
    /// resolved to the second — so bringing the phone into range with the app idle
    /// fired `sessionReachabilityDidChange`, re-derived, and printed "With the
    /// phone" about a capture that was never taken.
    @Test("An empty outbox with nothing ever handed over is ready, not with the phone")
    func emptyOutboxWithNoHandoffIsReady() {
        let status = WristStatus.derive(outstanding: 0, failed: 0, handedOver: 0)
        #expect(status == .ready)
        #expect(status != .withPhone)
    }

    @Test("An empty outbox after a hand-off means the phone took everything")
    func emptyOutboxAfterAHandoffIsWithPhone() {
        #expect(WristStatus.derive(outstanding: 0, failed: 0, handedOver: 1) == .withPhone)
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

    /// Reversed in #28, because `failed` changed meaning in #29. It used to mean
    /// "a transfer errored"; it now means "this capture is permanently gone, so
    /// capture it again". Telling the user to capture again while another transfer
    /// is still in flight makes them re-dictate a capture that was never lost, and
    /// the re-dictation gets a fresh id, so the phone stores a genuine duplicate.
    ///
    /// The loss is not dropped, only deferred: ``LostCaptureLog`` is durable, so it
    /// renders as soon as it is the only news.
    @Test("A pending transfer outranks a loss, so the advice is never premature")
    func waitingOutranksFailureWhileSomethingIsInFlight() {
        #expect(
            WristStatus.derive(outstanding: 1, failed: 1)
                == .waiting(count: 1, phoneNearby: true)
        )
    }

    @Test("The loss surfaces once the outbox is empty")
    func failureSurfacesWhenNothingIsInFlight() {
        #expect(WristStatus.derive(outstanding: 0, failed: 1) == .failed(count: 1))
    }

    /// A loss is a fact about a capture, not about the session, so a later
    /// hand-off must not bury it.
    @Test("A hand-off since the loss does not turn the loss into success")
    func handoffDoesNotEraseALoss() {
        let status = WristStatus.derive(outstanding: 0, failed: 1, handedOver: 3)
        #expect(status == .failed(count: 1))
        #expect(status != .withPhone)
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
    @Test("Nonsense counts fall through rather than render")
    func negativeCountsFallThrough() {
        #expect(WristStatus.derive(outstanding: -1, failed: 0, handedOver: 0) == .ready)
        #expect(WristStatus.derive(outstanding: 0, failed: -1, handedOver: 0) == .ready)
        #expect(WristStatus.derive(outstanding: -1, failed: 0, handedOver: 1) == .withPhone)
    }
}
