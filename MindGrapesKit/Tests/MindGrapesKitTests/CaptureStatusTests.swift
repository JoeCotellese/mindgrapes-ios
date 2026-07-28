// ABOUTME: Asserts the capture screen's status state machine over outcomes, drains, and setup failures.
// ABOUTME: The copy itself lives in the app target; this fixes which state each input produces.

import Testing

@testable import MindGrapesKit

@Suite("CaptureStatus")
struct CaptureStatusTests {
    // MARK: - Capture outcomes

    @Test("A confirmed capture reads as saved and carries the server id")
    func confirmedIsSaved() {
        #expect(CaptureStatus(outcome: .confirmed(experienceID: "exp_123")) == .saved(experienceID: "exp_123"))
    }

    @Test("A queued capture reads as queued, which is a success")
    func queuedIsQueued() {
        #expect(CaptureStatus(outcome: .queued) == .queued)
        #expect(CaptureStatus(outcome: .queued).isFailure == false)
    }

    @Test("A parked capture asks for sign-in rather than blaming the network")
    func needsSignInIsItsOwnState() {
        #expect(CaptureStatus(outcome: .needsSignIn) == .needsSignIn)
    }

    @Test("A terminal server rejection is a failure, not a silent will-sync")
    func failedIsFailure() {
        #expect(CaptureStatus(outcome: .failed) == .sendFailed)
    }

    @Test("An empty note is user-fixable input, distinct from a lost capture")
    func emptyIsNotLoss() {
        #expect(CaptureStatus(outcome: .rejected(reason: "empty")) == .nothingToSave)
    }

    @Test("A durable-write failure must not read as merely empty input")
    func saveFailedIsLoss() {
        // SPEC: "save_failed" means the capture was lost. Collapsing it into
        // .nothingToSave would tell the user their input was blank when in fact
        // their words are gone.
        #expect(CaptureStatus(outcome: .rejected(reason: "save_failed")) == .captureLost)
    }

    @Test("An unreadable image is user-fixable input, not a loss")
    func badImageIsNotLoss() {
        #expect(CaptureStatus(outcome: .rejected(reason: "bad_image")) == .unreadableImage)
    }

    @Test("An unknown rejection reason falls back to loss rather than to blank input")
    func unknownRejectionIsTreatedAsLoss() {
        // The safe default: telling the user nothing was saved when something was
        // is recoverable; telling them it saved when it did not is not.
        #expect(CaptureStatus(outcome: .rejected(reason: "something_new")) == .captureLost)
    }

    // MARK: - Failure classification

    @Test("Only the states that need the user count as failures")
    func failureClassification() {
        #expect(CaptureStatus.saved(experienceID: "x").isFailure == false)
        #expect(CaptureStatus.ready.isFailure == false)
        #expect(CaptureStatus.working.isFailure == false)
        #expect(CaptureStatus.needsSignIn.isFailure)
        #expect(CaptureStatus.sendFailed.isFailure)
        #expect(CaptureStatus.captureLost.isFailure)
        #expect(CaptureStatus.storageUnavailable.isFailure)
        #expect(CaptureStatus.nothingToSave.isFailure)
        #expect(CaptureStatus.unreadableImage.isFailure)
        #expect(CaptureStatus.notSignedIn.isFailure)
    }

    @Test("Signed-out is not the same state as a capture parked for re-auth")
    func signedOutIsNotParked() {
        // Both ask the user to sign in, but only one of them has a capture
        // waiting, and saying "saved" to someone who has captured nothing is a
        // lie the screen should not tell.
        #expect(CaptureStatus.notSignedIn != CaptureStatus.needsSignIn)
        #expect(CaptureStatus.notSignedIn.draftBecameDurable == false)
    }

    @Test("The field clears only when the capture actually became durable")
    func clearsDraftOnlyWhenDurable() {
        #expect(CaptureStatus(outcome: .confirmed(experienceID: "x")).draftBecameDurable)
        #expect(CaptureStatus(outcome: .queued).draftBecameDurable)
        #expect(CaptureStatus(outcome: .needsSignIn).draftBecameDurable)
        // Enqueued but terminally rejected: still durable, still off the screen.
        #expect(CaptureStatus(outcome: .failed).draftBecameDurable)
        // Nothing was enqueued, so the user's words must stay in the field.
        #expect(CaptureStatus(outcome: .rejected(reason: "empty")).draftBecameDurable == false)
        #expect(CaptureStatus(outcome: .rejected(reason: "save_failed")).draftBecameDurable == false)
    }

    // MARK: - Drain results

    @Test("A drain that lands everything reads as synced")
    func drainAllSucceeded() {
        #expect(CaptureStatus(drainedPending: 0, sawFailure: false) == .synced)
    }

    @Test("A drain with work left over says so rather than claiming success")
    func drainWithPendingLeft() {
        #expect(CaptureStatus(drainedPending: 3, sawFailure: false) == .pending(count: 3))
    }

    @Test("A failure during a drain outranks a leftover count")
    func drainFailureWins() {
        // Otherwise "2 still pending" reads as patience when the truth is that the
        // server refused them.
        #expect(CaptureStatus(drainedPending: 2, sawFailure: true) == .sendFailed)
    }

    @Test("A drain that had nothing to do leaves the screen alone")
    func emptyDrainIsReady() {
        #expect(CaptureStatus(drainedPending: 0, sawFailure: false, drainedAnything: false) == .ready)
    }

    @Test("A drain that parked everything for re-auth must not claim a sync")
    func drainParkedForAuth() {
        // A parked record is neither pending nor failed, so without this it fell
        // through to .synced and announced "All captures synced" over a queue
        // that had delivered nothing.
        #expect(CaptureStatus(drainedPending: 0, sawFailure: false, sawAuthRequired: true) == .needsSignIn)
    }

    @Test("Re-auth outranks both leftovers and failures, because it is the unblocking action")
    func authOutranksTheRest() {
        #expect(CaptureStatus(drainedPending: 4, sawFailure: true, sawAuthRequired: true) == .needsSignIn)
    }
}
