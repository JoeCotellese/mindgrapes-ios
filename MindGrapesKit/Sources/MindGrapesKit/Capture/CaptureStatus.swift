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

    /// A capture or a drain is in flight.
    case working

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
    /// - Parameters:
    ///   - drainedPending: captures still not delivered when the pass ended.
    ///   - sawFailure: whether any record in the pass ended terminally failed.
    ///   - sawAuthRequired: whether any record parked for re-auth. Such a record
    ///     is neither pending nor failed, so without this input a pass that
    ///     parked everything falls through to ``synced`` and announces a delivery
    ///     that did not happen.
    ///   - drainedAnything: whether the pass had any records at all. A pass over
    ///     an empty queue is the common case on every foreground and must not
    ///     announce a sync that did not happen.
    public init(
        drainedPending: Int,
        sawFailure: Bool,
        sawAuthRequired: Bool = false,
        drainedAnything: Bool = true
    ) {
        // Signing in again is the one action that unblocks the queue, so it is the
        // one to name — ahead of a count the user cannot act on and a failure they
        // cannot retry.
        if sawAuthRequired {
            self = .needsSignIn
        } else if sawFailure {
            self = .sendFailed
        } else if !drainedAnything {
            self = .ready
        } else if drainedPending > 0 {
            self = .pending(count: drainedPending)
        } else {
            self = .synced
        }
    }

    /// Whether this state needs something from the user. Drives the status line's
    /// emphasis, and keeps "will sync" from being styled like a problem.
    public var isFailure: Bool {
        switch self {
        case .ready, .working, .saved, .queued, .pending, .synced, .locationOff:
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
        case .saved, .queued, .needsSignIn, .sendFailed: true
        default: false
        }
    }
}
