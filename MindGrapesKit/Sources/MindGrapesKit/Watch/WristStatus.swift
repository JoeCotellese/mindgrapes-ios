// ABOUTME: Every state the wrist is allowed to be in about a capture it took.
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
/// It lives in the kit, not in the watch target, because the rule that produces
/// it has to be tested and the watch app has no test target (#24). The wording
/// stays on the wrist: see `WristStatus+Copy.swift` in `MindGrapesWatch`.
public enum WristStatus: Equatable, Sendable {
    /// The session has not finished activating, so the outstanding count is not
    /// yet knowable. Reachable on every raise-to-wake relaunch, because watchOS
    /// terminates watch apps aggressively, so this is a normal state and not a
    /// startup edge case.
    case activating

    /// Activated, nothing outstanding, nothing handed over yet this session.
    case ready

    /// `count` captures are in the system outbox waiting for the counterpart app
    /// to take them. Not lost: `transferUserInfo` retries until it lands, across
    /// termination and reboot (SPEC 8.1).
    ///
    /// `phoneNearby` carries reachability because "waiting" means something
    /// different in each case — seconds away versus hours away — and reachability
    /// is a fact the wrist legitimately has.
    case waiting(count: Int, phoneNearby: Bool)

    /// The phone has taken everything handed to it. Says nothing about the server,
    /// and expires back to ``ready`` so it reads as an event rather than a standing
    /// guarantee of good health.
    case withPhone

    /// `count` transfers finished with an error and will not retry on their own.
    /// The wrist cannot fix this, so the line names the one thing the user can do.
    case failed(count: Int)

    /// The phone has no MindGrapes app, so nothing handed over will ever be taken.
    /// Distinct from ``waiting`` because no amount of patience resolves it.
    case companionAppMissing

    /// Dictation came back with nothing usable, so nothing was handed over.
    ///
    /// This is the wrist's own rejection, and it belongs to whoever owns the
    /// session: the phone must never be the one to discover a capture was blank,
    /// because by then the wrist has already reported a handoff that did not
    /// happen.
    case nothingHeard

    /// The state implied by the session's own bookkeeping.
    ///
    /// Two things make this a function rather than an assignment at each callback,
    /// and both are bugs that were found rather than anticipated:
    ///
    /// - **The outbox emptying does not mean success.** A transfer that finishes
    ///   *with* an error is removed from `outstandingUserInfoTransfers` exactly like
    ///   a successful one, so `failed` is a separate input and an empty list never
    ///   decides on its own.
    /// - **Whoever finished last must not decide.** With two captures outstanding,
    ///   assigning status in the completion callback lets the first completion
    ///   announce "With the phone" while the second is still in the outbox.
    ///
    /// - Parameters:
    ///   - outstanding: `WCSession.outstandingUserInfoTransfers.count`.
    ///   - failed: transfers that came back with a non-nil error and were not
    ///     retried.
    ///   - phoneNearby: `WCSession.isReachable`.
    ///   - companionAppInstalled: `WCSession.isCompanionAppInstalled`.
    public static func derive(
        outstanding: Int,
        failed: Int,
        phoneNearby: Bool = true,
        companionAppInstalled: Bool = true
    ) -> WristStatus {
        // Ordered by what the user can act on, most actionable first. A missing
        // counterpart app is terminal for every capture, not just the ones counted
        // here, so it wins outright.
        guard companionAppInstalled else { return .companionAppMissing }

        // Clamped because a hand-maintained failure counter that double-decrements
        // would otherwise render "-1 waiting for the phone".
        if failed > 0 { return .failed(count: failed) }
        if outstanding > 0 { return .waiting(count: outstanding, phoneNearby: phoneNearby) }
        return .withPhone
    }
}
