// ABOUTME: The two-and-a-half states the wrist is allowed to report about a capture.
// ABOUTME: Deliberately cannot express "delivered": the Watch never learns that (SPEC 10.8).

import Foundation

/// What the wrist knows about the captures it has handed over.
///
/// SPEC 10.8: the status glyph reports the *handoff*, not a delivery. The Watch
/// holds no tokens and never talks to the server, so it cannot know whether a
/// capture reached the brain — and must not imply that it does. This type is the
/// enforcement of that rule: there is no case for "saved", and no way to add one
/// without a spec change.
enum HandoffStatus: Equatable, Sendable {
    /// Nothing has been handed over yet. Reports nothing rather than inventing a
    /// state: "with the phone" before anything was sent would describe a capture
    /// that does not exist.
    case ready

    /// `count` captures are sitting in the system outbox waiting for the
    /// counterpart app to take them. Not lost: `transferUserInfo` retries until it
    /// lands, across termination and reboot (SPEC 8.1).
    case waiting(count: Int)

    /// The phone has taken everything handed to it. Says nothing about the server.
    case withPhone

    /// The user-facing line. Lower case "phone" reads as a place, which is the
    /// point: the capture is somewhere, and that somewhere is not the brain yet.
    var message: String {
        switch self {
        case .ready:
            ""
        case .waiting(let count) where count > 1:
            "\(count) waiting for the phone"
        case .waiting:
            "Waiting for the phone"
        case .withPhone:
            "With the phone"
        }
    }

    /// SF Symbol for the line. No checkmark anywhere: a checkmark on a wrist reads
    /// as "done", and done is exactly the claim this screen cannot make.
    var symbolName: String {
        switch self {
        case .ready: "mic"
        case .waiting: "clock"
        case .withPhone: "iphone"
        }
    }
}
