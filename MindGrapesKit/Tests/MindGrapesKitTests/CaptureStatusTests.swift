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
        #expect(CaptureStatus.syncing.isFailure == false)
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

    // MARK: - Losing location on the way

    @Test("A landed capture that lost its location says both things, not one")
    func successCombinesWithLocationNews() {
        // An earlier version replaced the outcome outright. That reads fine for a
        // note, where the emptied field confirms the save, and loses the only
        // confirmation a photo capture ever gets.
        #expect(CaptureStatus.saved(experienceID: "x").resolving(locationJustDenied: true) == .savedWithoutLocation)
        #expect(CaptureStatus.queued.resolving(locationJustDenied: true) == .savedWithoutLocation)
        #expect(CaptureStatus.savedWithoutLocation.draftBecameDurable)
        #expect(CaptureStatus.savedWithoutLocation.isFailure == false)
    }

    @Test("Anything needing the user outranks the location news")
    func failureOutranksLocationNews() {
        #expect(CaptureStatus.sendFailed.resolving(locationJustDenied: true) == .sendFailed)
        #expect(CaptureStatus.captureLost.resolving(locationJustDenied: true) == .captureLost)
        #expect(CaptureStatus.needsSignIn.resolving(locationJustDenied: true) == .needsSignIn)
    }

    @Test("Nothing changes when location was not just denied")
    func noLocationNewsIsIdentity() {
        #expect(CaptureStatus.saved(experienceID: "x").resolving(locationJustDenied: false)
            == .saved(experienceID: "x"))
        #expect(CaptureStatus.queued.resolving(locationJustDenied: false) == .queued)
    }

    // MARK: - Drain results

    @Test("A drain that empties the queue reads as synced")
    func drainAllSucceeded() {
        #expect(
            CaptureStatus(outstanding: 0, parked: false, failedThisPass: false, deliveredThisPass: true)
                == .synced
        )
    }

    @Test("Backlog left in the queue is reported, not rounded down to success")
    func drainWithPendingLeft() {
        #expect(
            CaptureStatus(outstanding: 3, parked: false, failedThisPass: false, deliveredThisPass: true)
                == .pending(count: 3)
        )
    }

    @Test("A capture in retry backoff still counts as outstanding")
    func backedOffCaptureStillCounts() {
        // The bug this fixes: backoff leaves a record pending-but-not-due, so it
        // never appears in a drain pass. Counting only what the pass touched
        // announced "All captures synced" over a queue that still owed a delivery.
        // The count comes from the queue, so a pass that delivered one capture
        // while another sits in backoff reports the backlog.
        #expect(
            CaptureStatus(outstanding: 1, parked: false, failedThisPass: false, deliveredThisPass: true)
                == .pending(count: 1)
        )
    }

    @Test("A failure in this pass outranks a leftover count")
    func drainFailureWins() {
        // Otherwise "2 still pending" reads as patience when the truth is that the
        // server refused them.
        #expect(
            CaptureStatus(outstanding: 2, parked: false, failedThisPass: true, deliveredThisPass: true)
                == .sendFailed
        )
    }

    @Test("A pass that had nothing to do leaves the screen alone")
    func emptyDrainIsReady() {
        #expect(
            CaptureStatus(outstanding: 0, parked: false, failedThisPass: false, deliveredThisPass: false)
                == .ready
        )
    }

    @Test("A contended pass reports the real backlog rather than an empty queue")
    func contendedDrainReportsBacklog() {
        // drainOnce returns [] when another drain holds the gate. Read as "nothing
        // to do" that silently cleared the line; the queue-wide count makes the
        // contended pass indistinguishable from a quiet one, which is correct.
        #expect(
            CaptureStatus(outstanding: 2, parked: false, failedThisPass: false, deliveredThisPass: false)
                == .pending(count: 2)
        )
    }

    @Test("A queue parked for re-auth must not claim a sync")
    func drainParkedForAuth() {
        // A parked record is neither pending nor failed, so without this it fell
        // through to .synced and announced "All captures synced" over a queue
        // that had delivered nothing.
        #expect(
            CaptureStatus(outstanding: 0, parked: true, failedThisPass: false, deliveredThisPass: false)
                == .needsSignIn
        )
    }

    @Test("Re-auth outranks both leftovers and failures, because it is the unblocking action")
    func authOutranksTheRest() {
        #expect(
            CaptureStatus(outstanding: 4, parked: true, failedThisPass: true, deliveredThisPass: true)
                == .needsSignIn
        )
    }
}
