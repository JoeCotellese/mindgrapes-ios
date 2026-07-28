// ABOUTME: The capture screen's single status state, derived from capture outcomes and drain results.
// ABOUTME: State only — the user-facing copy lives in the app target, as WristStatus does for the watch.

import Foundation

/// What the capture screen currently has to say.
///
/// The screen has several producers writing to one status slot — a save, a
/// foreground drain, a failed setup, a denied location — and before this they
/// each wrote free-form strings. That made the slot untestable and let a
/// low-stakes message overwrite a high-stakes one. This enum is the state; the
/// copy is an extension in the app target, mirroring ``WristStatus`` and
/// `WristStatus+Copy`.
public enum CaptureStatus: Equatable, Sendable {
    /// Nothing to report. The resting state.
    case ready

    /// A capture the user just made is in flight.
    case working

    /// A background flush of the queue is in flight. Distinct from ``working``
    /// because it is not the user's capture and must not say "Saving".
    case syncing

    /// Delivered and confirmed by the server within the budget.
    case saved(experienceID: String)

    /// Durable and will sync, but not confirmed within the budget. A success.
    case queued

    /// `count` captures are still waiting after a drain pass.
    case pending(count: Int)

    /// A drain landed everything it was holding.
    case synced

    /// Durable, but parked until the user signs in again. Connectivity is not
    /// the problem, so this must not read as "will sync".
    case needsSignIn

    /// Enqueued, and the server refused it terminally. It will not sync on its
    /// own.
    case sendFailed

    /// Nothing was enqueued because there was nothing usable to enqueue. The
    /// user's words are still in the field.
    case nothingToSave

    /// Nothing was enqueued because the image would not decode.
    case unreadableImage

    /// Nothing was enqueued and the capture is gone: the durable write itself
    /// failed. Deliberately distinct from ``nothingToSave`` — see `init(outcome:)`.
    case captureLost

    /// Local storage would not open, so the screen cannot capture at all.
    case storageUnavailable

    /// The install has no session at all, so nothing has been captured and
    /// nothing is waiting. Distinct from ``needsSignIn``, which means a real
    /// capture is parked — telling a signed-out user their capture is waiting
    /// names a capture that does not exist.
    case notSignedIn

    /// The location toggle was on but permission is denied, so this capture
    /// carried no location.
    case locationOff

    /// The capture landed **and** location was just turned off, said in one line
    /// because there is only one line. See ``resolving(locationJustDenied:)``.
    case savedWithoutLocation

    /// The state a finished capture leaves on screen.
    ///
    /// The `rejected` reasons are split rather than collapsed because they differ
    /// in whether the user still has their words. `"empty"` and `"bad_image"` are
    /// fixable input; `"save_failed"` means the durable write failed and the
    /// capture is gone (SPEC, ``CaptureOutcome/rejected(reason:)``). An unknown
    /// reason takes the loss branch: over-reporting a loss sends the user to
    /// re-capture something they still have, while under-reporting one loses it
    /// silently.
    public init(outcome: CaptureOutcome) {
        switch outcome {
        case .confirmed(let experienceID): self = .saved(experienceID: experienceID)
        case .queued: self = .queued
        case .needsSignIn: self = .needsSignIn
        case .failed: self = .sendFailed
        case .rejected(let reason):
            switch reason {
            case "empty": self = .nothingToSave
            case "bad_image": self = .unreadableImage
            default: self = .captureLost
            }
        }
    }

    /// The state a drain pass leaves on screen.
    ///
    /// The backlog inputs describe the **whole queue**, not the records the pass
    /// happened to touch. Deriving them from a pass is what made an earlier
    /// version claim "All captures synced" over a queue that still held work: a
    /// record in retry backoff is `pending` but not yet due, so
    /// ``CaptureQueue/claimDue(now:)`` never returns it and it counted as zero.
    /// A contended pass has the same shape — ``CaptureDrainer/drainOnce(now:)``
    /// returns `[]` when another drain holds the gate, which is indistinguishable
    /// from an empty queue unless the count comes from the queue itself.
    ///
    /// - Parameters:
    ///   - outstanding: every record still owed a delivery — `pending` and
    ///     `inFlight` alike, due or not.
    ///   - parked: whether any record is waiting on re-auth. Such a record is
    ///     neither pending nor failed, so without this a queue that parked
    ///     everything falls through to ``synced``.
    ///   - failedThisPass: whether a record failed terminally *in this pass*.
    ///     Deliberately not queue-wide: a failure sticks around for the retention
    ///     window, and reading it queue-wide would re-announce week-old news on
    ///     every foreground. Old failures belong in the recent-captures list.
    ///   - deliveredThisPass: whether the pass actually landed anything. Separates
    ///     "everything synced" from "there was nothing to do", which an
    ///     `outstanding` of zero cannot do on its own.
    public init(outstanding: Int, parked: Bool, failedThisPass: Bool, deliveredThisPass: Bool) {
        // Signing in again is the one action that unblocks the queue, so it is the
        // one to name — ahead of a count the user cannot act on and a failure they
        // cannot retry.
        if parked {
            self = .needsSignIn
        } else if failedThisPass {
            self = .sendFailed
        } else if outstanding > 0 {
            self = .pending(count: outstanding)
        } else if deliveredThisPass {
            self = .synced
        } else {
            self = .ready
        }
    }

    /// Folds in the news that this capture lost its location, when there is room
    /// for it.
    ///
    /// Two true things compete for one line. A state that needs the user always
    /// wins, because a location explanation must never displace "that capture
    /// couldn't be saved". A plain success does not simply yield, though: an
    /// earlier version replaced ``saved`` outright, which worked for a note (the
    /// emptied field is its own confirmation) and lost the only confirmation a
    /// *photo* capture ever gets. So the two are combined rather than ranked.
    public func resolving(locationJustDenied: Bool) -> CaptureStatus {
        guard locationJustDenied else { return self }
        switch self {
        case .saved, .queued: return .savedWithoutLocation
        // Anything else either needs the user, in which case it outranks this, or
        // never captured anything for the location to be missing from.
        default: return self
        }
    }

    /// Whether this state needs something from the user. Drives the status line's
    /// emphasis, and keeps "will sync" from being styled like a problem.
    public var isFailure: Bool {
        switch self {
        case .ready, .working, .syncing, .saved, .queued, .pending, .synced, .locationOff,
            .savedWithoutLocation:
            false
        case .needsSignIn, .sendFailed, .nothingToSave, .unreadableImage, .captureLost, .storageUnavailable,
            .notSignedIn:
            true
        }
    }

    /// Whether the capture reached durable storage, and so whether the compose
    /// field may be cleared.
    ///
    /// Enqueued-then-refused (``sendFailed``) still counts: the record exists and
    /// re-typing it would duplicate rather than rescue it. Anything that never
    /// enqueued does not, or the user watches their words vanish into nothing.
    public var draftBecameDurable: Bool {
        switch self {
        case .saved, .queued, .needsSignIn, .sendFailed, .savedWithoutLocation: true
        default: false
        }
    }
}
