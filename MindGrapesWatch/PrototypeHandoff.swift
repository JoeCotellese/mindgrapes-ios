// ABOUTME: Stand-in for the WCSession relay so the capture screen renders with no counterpart app.
// ABOUTME: ponytail: prototype only — /implement replaces this with WatchCaptureRelay and deletes it.

import Foundation
import Observation

/// Drives ``CaptureView`` during the design phase.
///
/// The real thing (`WatchCaptureRelay`, issue #22) stamps the capture's `id`,
/// `occurredAt`, and location fix on the wrist, hands the payload to
/// `WCSession.transferUserInfo`, and derives its status from
/// `outstandingUserInfoTransfers` plus the `didFinish` delegate callback. None of
/// that renders in a simulator without a paired phone running the counterpart
/// app, which is exactly why the screen takes its status from outside.
///
/// A launch argument pins the state so each one can be screenshotted:
/// `-prototypeStatus ready | waiting | waitingSeveral | withPhone`.
@MainActor
@Observable
final class PrototypeHandoff {
    private(set) var status: HandoffStatus

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        status = Self.status(from: arguments)
    }

    /// Mimics a handoff: the capture goes to the outbox, then the phone takes it.
    func capture(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let waiting = if case .waiting(let count) = status { count + 1 } else { 1 }
        status = .waiting(count: waiting)
        Task {
            try? await Task.sleep(for: .seconds(2))
            status = .withPhone
        }
    }

    private static func status(from arguments: [String]) -> HandoffStatus {
        guard let index = arguments.firstIndex(of: "-prototypeStatus"),
              let value = arguments[safe: index + 1]
        else { return .ready }

        return switch value {
        case "waiting": .waiting(count: 1)
        case "waitingSeveral": .waiting(count: 3)
        case "withPhone": .withPhone
        default: .ready
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
