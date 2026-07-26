// ABOUTME: Stand-in for the WCSession relay so the capture screen renders with no counterpart app.
// ABOUTME: ponytail: prototype only — /implement replaces this with WatchCaptureRelay and deletes it.

import Foundation
import Observation
import WatchKit

/// Drives ``WristCaptureView`` during the design phase.
///
/// The real thing (`WatchCaptureRelay`, issue #22) stamps the capture's `id`,
/// `occurredAt`, and location fix on the wrist, hands the payload to
/// `WCSession.transferUserInfo`, and derives its status from
/// `outstandingUserInfoTransfers` plus the `didFinish userInfoTransfer:error:`
/// callback. None of that renders in a simulator without a paired phone running
/// the counterpart app, which is why the screen takes its status from outside.
///
/// Two things here are the shape the real relay has to keep, not prototype
/// scaffolding:
///
/// - **Status is derived from a count, never assigned by whoever finished last.**
///   With two captures outstanding, an assignment would let the first completion
///   announce "With the phone" while the second is still in the outbox — the
///   wrist claiming a handoff that has not happened.
/// - **A failure is counted separately from the outbox emptying.** A failed
///   transfer leaves `outstandingUserInfoTransfers` just as empty as a successful
///   one, so the error is the thing that decides, not the empty list.
///
/// Launch arguments (parsed by `UserDefaults`, which already reads the argument
/// domain): `-prototypeStatus activating|ready|waiting|waitingSeveral|withPhone|failed|nothingHeard`
/// pins one state for screenshots and disables the timers; `-prototypeFailTransfers YES`
/// makes every handoff come back with an error.
@MainActor
@Observable
final class PrototypeHandoff {
    private(set) var status: WristStatus

    /// Set when a launch argument pins the state, so no timer moves it afterwards.
    private let isPinned: Bool
    private let failsTransfers: Bool

    private var outstanding = 0
    private var failures = 0
    /// Invalidates a pending expiry when a newer capture supersedes it.
    private var generation = 0

    init(defaults: UserDefaults = .standard) {
        let pinned = defaults.string(forKey: "prototypeStatus").flatMap(Self.status(named:))
        status = pinned ?? .activating
        isPinned = pinned != nil
        failsTransfers = defaults.bool(forKey: "prototypeFailTransfers")

        guard !isPinned else { return }
        // Models WCSession activation, which is a real state on every raise-to-wake
        // relaunch: watchOS terminates watch apps aggressively.
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            if case .activating = status { status = .ready }
        }
    }

    /// Validates on the wrist, then hands over. The blank check lives here and not
    /// in the view because this is the only place that can report
    /// ``WristStatus/nothingHeard``, and letting the phone discover a blank
    /// capture would mean the wrist had already reported a handoff that did not
    /// happen.
    func submit(_ text: String) {
        guard !isPinned else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = .nothingHeard
            return
        }

        outstanding += 1
        generation += 1
        recompute()
        // The primary story is "tap, speak, lower your wrist", so the screen is
        // the wrong channel for the only signal that matters. A haptic on the
        // handoff makes no claim about delivery.
        WKInterfaceDevice.current().play(.click)

        let scheduled = generation
        Task {
            try? await Task.sleep(for: .seconds(2))
            finishOne(generation: scheduled)
        }
    }

    private func finishOne(generation scheduled: Int) {
        outstanding -= 1
        if failsTransfers {
            failures += 1
            WKInterfaceDevice.current().play(.failure)
        }
        recompute()

        // "With the phone" describes one past event, so it expires rather than
        // standing as a permanent claim of good health.
        guard status == .withPhone else { return }
        Task {
            try? await Task.sleep(for: .seconds(10))
            guard scheduled == generation, status == .withPhone else { return }
            status = .ready
        }
    }

    private func recompute() {
        status = if failures > 0 {
            .failed(count: failures)
        } else if outstanding > 0 {
            .waiting(count: outstanding)
        } else {
            .withPhone
        }
    }

    private static func status(named name: String) -> WristStatus? {
        switch name {
        case "activating": .activating
        case "ready": .ready
        case "waiting": .waiting(count: 1)
        case "waitingSeveral": .waiting(count: 3)
        case "withPhone": .withPhone
        case "failed": .failed(count: 1)
        case "nothingHeard": .nothingHeard
        default: nil
        }
    }
}
