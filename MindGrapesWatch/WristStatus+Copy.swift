// ABOUTME: The words and glyphs for each WristStatus, kept on the wrist rather than in the kit.
// ABOUTME: The kit owns the rule that picks a state; this file owns what the user reads.

import MindGrapesKit

/// User-facing copy for ``WristStatus``.
///
/// Split from the enum deliberately. The state machine is the honesty constraint
/// and lives in `MindGrapesKit` where it is tested (`WristStatusTests`); the
/// wording is presentation and belongs next to the view that renders it.
///
/// Every case has a message. No case renders blank, because a blank line that
/// sometimes means "first launch", sometimes "still activating", and sometimes
/// "your dictation was dropped" is not silence, it is ambiguity.
extension WristStatus {
    /// Lower-case "phone" reads as a place, which is the point: the capture is
    /// somewhere, and that somewhere is not the brain yet.
    var message: String {
        switch self {
        case .activating:
            "Getting ready"
        case .ready:
            "Captures go to your phone"
        case .waiting(let count, true) where count > 1:
            "\(count) waiting for the phone"
        case .waiting(_, true):
            "Waiting for the phone"
        case .waiting(let count, false) where count > 1:
            "\(count) waiting. Phone not nearby."
        case .waiting(_, false):
            "Phone not nearby. Will send later."
        case .withPhone:
            "With the phone"
        // "Open the phone app" was a lie: it might help a future transfer, but by
        // the time this renders the capture has already failed twice and is gone.
        // Capturing again is the only thing that recovers it.
        case .failed(let count) where count > 1:
            "\(count) not handed off. Capture again."
        case .failed:
            "Not handed off. Capture again."
        case .companionAppMissing:
            "No MindGrapes on your phone."
        case .nothingHeard:
            "Nothing heard. Try again."
        }
    }

    /// No checkmark in the set, at any severity: a checkmark on a wrist reads as
    /// "done", and done is exactly the claim this screen cannot make.
    ///
    /// Reachable and unreachable waiting share the clock glyph. The distinction is
    /// in the words, and a second waiting-ish symbol would read as a different kind
    /// of problem rather than the same wait with more context.
    var symbolName: String {
        switch self {
        case .activating: "ellipsis"
        case .ready: "mic"
        case .waiting: "clock"
        case .withPhone: "iphone"
        case .failed: "exclamationmark.triangle"
        case .companionAppMissing: "iphone.slash"
        case .nothingHeard: "exclamationmark.circle"
        }
    }
}
