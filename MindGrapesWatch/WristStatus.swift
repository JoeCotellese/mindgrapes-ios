// ABOUTME: Every line the wrist is allowed to print about a capture it took.
// ABOUTME: Deliberately cannot express "delivered": the Watch never learns that (SPEC 10.8).

import Foundation

/// What the wrist knows, and is therefore allowed to say, about the captures it
/// has taken.
///
/// SPEC 10.8: the status line reports the *handoff*, not a delivery. The Watch
/// holds no tokens and never talks to the server, so it cannot know whether a
/// capture reached the brain — and must not imply that it does. This type is the
/// enforcement of that rule rather than a convention about it: there is no case
/// for "saved", and adding one would be a visible spec change rather than a
/// one-line drift in a view.
///
/// The rule cuts the other way too, which is the subtler half. A failed transfer
/// leaves `WCSession.outstandingUserInfoTransfers` just as empty as a successful
/// one, so a status derived from "the outbox is empty" reports failure as
/// success. ``failed(count:)`` exists so the empty outbox is never the thing that
/// decides; the error passed to `didFinish userInfoTransfer:error:` is.
///
/// Every case carries a message. No case renders blank, because a blank line that
/// sometimes means "first launch", sometimes "still activating", and sometimes
/// "your dictation was dropped" is not silence, it is ambiguity.
enum WristStatus: Equatable, Sendable {
    /// The session has not finished activating, so the outstanding count is not
    /// yet knowable. Reachable on every raise-to-wake relaunch, and watchOS
    /// terminates watch apps aggressively, so this is a normal state and not a
    /// startup edge case.
    case activating

    /// Activated, nothing outstanding, nothing handed over yet this session.
    case ready

    /// `count` captures are in the system outbox waiting for the counterpart app
    /// to take them. Not lost: `transferUserInfo` retries until it lands, across
    /// termination and reboot (SPEC 8.1).
    case waiting(count: Int)

    /// The phone has taken everything handed to it. Says nothing about the server,
    /// and expires back to ``ready`` so it reads as an event rather than a
    /// standing guarantee of good health.
    case withPhone

    /// `count` transfers finished with an error and will not retry on their own.
    /// The wrist has no way to fix this, so the line names the one thing the user
    /// can do.
    case failed(count: Int)

    /// Dictation came back with nothing usable, so nothing was handed over.
    ///
    /// This is the wrist's own rejection, and it belongs to whoever owns the
    /// session: the phone must never be the one to discover a capture was blank,
    /// because by then the wrist has already reported a handoff that did not
    /// happen.
    case nothingHeard

    /// The user-facing line. Lower-case "phone" reads as a place, which is the
    /// point: the capture is somewhere, and that somewhere is not the brain yet.
    var message: String {
        switch self {
        case .activating:
            "Getting ready"
        case .ready:
            "Captures go to your phone"
        case .waiting(let count) where count > 1:
            "\(count) waiting for the phone"
        case .waiting:
            "Waiting for the phone"
        case .withPhone:
            "With the phone"
        case .failed(let count) where count > 1:
            "\(count) not handed off. Open the phone app."
        case .failed:
            "Not handed off. Open the phone app."
        case .nothingHeard:
            "Nothing heard. Try again."
        }
    }

    /// SF Symbol for the line. No checkmark in the set, at any severity: a
    /// checkmark on a wrist reads as "done", and done is exactly the claim this
    /// screen cannot make.
    var symbolName: String {
        switch self {
        case .activating: "ellipsis"
        case .ready: "mic"
        case .waiting: "clock"
        case .withPhone: "iphone"
        case .failed: "exclamationmark.triangle"
        case .nothingHeard: "exclamationmark.circle"
        }
    }
}
