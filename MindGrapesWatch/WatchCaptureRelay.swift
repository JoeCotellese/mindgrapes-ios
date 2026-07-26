// ABOUTME: Owns the wrist's WCSession: stamps a capture's identity and hands it to the system outbox.
// ABOUTME: The untestable half of the relay; every rule it applies lives in MindGrapesKit.

import Foundation
import MindGrapesKit
import Observation
import OSLog
import WatchConnectivity
import WatchKit

private let log = Logger(subsystem: "net.cotellese.mindgrapes", category: "watch")

/// The Watch's whole networking story: there is none (SPEC Decision 5).
///
/// A capture is stamped with its `id` and `occurredAt` here, on the wrist, and
/// handed to `WCSession.transferUserInfo`. That is a persistent FIFO outbox owned
/// by the system: it survives app termination and reboot and retries until the
/// counterpart takes it, which is why the Watch keeps no queue of its own
/// (SPEC 8.1). No tokens, no `BrainClient`, no socket.
///
/// This type is deliberately thin. `WCSession` has no injectable seam and no
/// behaviour without a paired counterpart, and the watch target has no test target
/// (#24), so the decisions live in `MindGrapesKit` where they are tested:
/// ``WristStatus/derive(outstanding:failed:phoneNearby:companionAppInstalled:)``
/// and ``WatchCapturePayload``.
@MainActor
@Observable
final class WatchCaptureRelay: NSObject {
    private(set) var status: WristStatus = .activating

    /// Transfers that came back with an error. Counted separately because a failed
    /// transfer is removed from `outstandingUserInfoTransfers` exactly like a
    /// successful one, so the outbox emptying is not evidence of success.
    private var failures = 0

    /// The fix taken while the user was dictating. See ``beginCapture()``.
    private var pendingCoordinate: Coordinate?
    private var locationTask: Task<Void, Never>?

    private let session: WCSession
    private let location: LocationProvider

    init(session: WCSession = .default, location: LocationProvider = .system()) {
        self.session = session
        self.location = location
        super.init()
    }

    /// Activates the session. Called from an explicit `.task`, never from an
    /// initializer: SwiftUI resolves a `@State` initial value lazily on first body
    /// evaluation, and whether the wrist can hand anything over must not depend on
    /// when the UI happened to appear.
    func activate() {
        guard WCSession.isSupported() else {
            // No counterpart is reachable on this device, ever. Says the true thing
            // rather than sitting in `activating` forever.
            status = .companionAppMissing
            log.error("WCSession is unsupported on this device")
            return
        }
        session.delegate = self
        session.activate()
    }

    /// Starts the location request when the user taps Capture, before they have
    /// said anything.
    ///
    /// The alternative — asking for a fix at submit time — forces a choice between
    /// waiting on CoreLocation (during which watchOS may suspend the app, and the
    /// capture is lost because it never reached the outbox) and handing over with no
    /// location at all. Dictating takes seconds, so starting the request when the
    /// sheet opens usually has a fix ready by the time the text comes back, and
    /// ``submit(_:)`` never waits for one.
    func beginCapture() {
        locationTask?.cancel()
        locationTask = nil
        pendingCoordinate = nil

        // No fix, and no permission prompt, unless the user asked for located
        // captures on the phone. The toggle lives in App Group UserDefaults the Watch
        // cannot read, so the phone pushes it with updateApplicationContext and the
        // system holds the last value for us. Absent means off: the wrist must never
        // prompt for something the user already declined on the phone (SPEC 9).
        guard session.receivedApplicationContext["includeLocation"] as? Bool == true else { return }

        // currentCoordinate deliberately skips the reverse geocode: CLGeocoder needs
        // network and a Watch with no phone nearby has none. The phone labels the
        // coordinate when it receives the handoff (SPEC 9, #22).
        locationTask = Task { [location] in
            let coordinate = await location.currentCoordinate()
            guard !Task.isCancelled else { return }
            pendingCoordinate = coordinate
        }
    }

    /// Validates on the wrist, stamps identity on the wrist, hands over immediately.
    ///
    /// The blank check is here and not on the phone: if the phone were the one to
    /// discover a capture was empty, the wrist would already have reported a handoff
    /// that never happened.
    func submit(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = .nothingHeard
            log.notice("dictation returned nothing usable; no transfer")
            return
        }

        let coordinate = pendingCoordinate
        pendingCoordinate = nil
        locationTask?.cancel()
        locationTask = nil

        guard let payload = WatchCapturePayload(
            id: UUID(), content: text, occurredAt: Date(), coordinate: coordinate
        ) else {
            status = .nothingHeard
            return
        }

        session.transferUserInfo(payload.userInfo)
        log.notice("handed \(payload.id, privacy: .public) to the outbox, coordinate: \(coordinate != nil)")

        // A haptic, because the story this app exists for is "tap, speak, lower your
        // wrist" — at which point the screen reaches nobody. A haptic on the handoff
        // makes no claim about delivery.
        WKInterfaceDevice.current().play(.click)
        refreshStatus()
    }

    /// Recomputes from the session's own bookkeeping rather than assigning whatever
    /// the last callback implies. With two captures outstanding, assigning in the
    /// completion callback lets the first completion announce "With the phone" while
    /// the second is still in the outbox.
    private func refreshStatus() {
        guard session.activationState == .activated else {
            status = .activating
            return
        }

        let derived = WristStatus.derive(
            outstanding: session.outstandingUserInfoTransfers.count,
            failed: failures,
            phoneNearby: session.isReachable,
            companionAppInstalled: session.isCompanionAppInstalled
        )

        // `withPhone` describes one past event. Left standing it reads as a guarantee
        // of good health in the exact screen position where every other app prints
        // "Saved", so it decays to the neutral line.
        guard derived == .withPhone else {
            status = derived
            return
        }
        if status == .activating {
            // Nothing was handed over this session; there is no event to report.
            status = .ready
            return
        }
        status = .withPhone
        expireWithPhone()
    }

    private var expiry: Task<Void, Never>?

    private func expireWithPhone() {
        expiry?.cancel()
        expiry = Task {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, status == .withPhone else { return }
            status = .ready
        }
    }
}

// MARK: - WCSessionDelegate

/// The delegate callbacks arrive off the main actor, so each one hops before
/// touching state. `nonisolated` plus an explicit `Task { @MainActor }` rather than
/// `assumeIsolated`: WatchConnectivity documents its own queue, so assuming would
/// be a lie that traps in debug.
extension WatchCaptureRelay: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        if let error {
            log.error("activation failed: \(error.localizedDescription, privacy: .public)")
        }
        Task { @MainActor in self.refreshStatus() }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.refreshStatus() }
    }

    nonisolated func sessionCompanionAppInstalledDidChange(_ session: WCSession) {
        Task { @MainActor in self.refreshStatus() }
    }

    /// The outbox emptying is not success. A transfer that finishes *with* an error
    /// is removed from `outstandingUserInfoTransfers` exactly like a successful one,
    /// so the error is what decides and it is counted rather than inspected later.
    nonisolated func session(
        _ session: WCSession,
        didFinish userInfoTransfer: WCSessionUserInfoTransfer,
        error: (any Error)?
    ) {
        let failed = error != nil
        if let error {
            log.error("transfer failed: \(error.localizedDescription, privacy: .public)")
        }
        Task { @MainActor in
            if failed {
                self.failures += 1
                WKInterfaceDevice.current().play(.failure)
            }
            self.refreshStatus()
        }
    }
}
