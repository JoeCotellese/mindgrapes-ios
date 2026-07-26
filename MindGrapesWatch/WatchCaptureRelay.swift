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

    /// Transfers that came back with an error and have no retry left. Counted
    /// separately because a failed transfer is removed from
    /// `outstandingUserInfoTransfers` exactly like a successful one, so the outbox
    /// emptying is not evidence of success.
    ///
    /// Captures that are actually gone. A first failure is re-handed rather than
    /// recorded, so the status line never reports a loss the relay is still
    /// working on.
    ///
    /// **Durable, and that is load-bearing.** The final failure of a capture is
    /// usually delivered to a background relaunch with the screen facing nobody,
    /// and watchOS terminates the app again moments later — so an in-memory count
    /// would be discarded before it was ever rendered and the user would never
    /// learn the capture was gone. See ``LostCaptureLog``.
    ///
    /// Deliberately *not* cleared by a later successful transfer. A lost capture
    /// stays lost, and a success on some other capture is not news about it: the
    /// old behaviour let capture B's success erase the report that capture A was
    /// gone, which is the same class of false claim ``WristStatus`` exists to
    /// prevent. It clears when the user captures again, because that is the one
    /// instruction the line gives them.
    private let lost = LostCaptureLog()

    /// The fix taken while the user was dictating. See ``beginCapture()``.
    private var pendingCoordinate: Coordinate?
    private var locationTask: Task<Void, Never>?

    /// Captures made before the session finished activating, held until it does.
    ///
    /// `transferUserInfo` raises on a session that is not activated rather than
    /// returning an error, and there is no error path to catch. watchOS relaunches
    /// this app on every raise-to-wake, at which point the Capture button is live
    /// and the status line still reads "Getting ready" — so a short dictation can
    /// reach ``submit(_:)`` while `activate()` is still in flight. Holding is the
    /// only option that neither crashes nor drops the capture.
    private var held: [WatchCapturePayload] = []

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

        // Unreachable while this check and `nonBlank` trim the same character set,
        // and kept anyway so a future change to either one fails closed.
        guard let payload = WatchCapturePayload(
            id: UUID(), content: text, occurredAt: Date(), coordinate: coordinate
        ) else {
            status = .nothingHeard
            return
        }

        // Cleared only once a capture is actually going out, so neither blank-input
        // return above wipes a loss report the user still needs. The user has acted
        // on "Not handed off. Capture again.", so that report has done its job.
        // Cleared here rather than on a successful transfer, so an unrelated
        // success cannot silently erase news the user never saw.
        lost.clear()

        handOver(payload)

        // A haptic, because the story this app exists for is "tap, speak, lower your
        // wrist" — at which point the screen reaches nobody. A haptic on the handoff
        // makes no claim about delivery.
        WKInterfaceDevice.current().play(.click)
        refreshStatus()
    }

    /// Hands one capture to the system outbox, or holds it if the session is not
    /// activated yet. See ``held``.
    private func handOver(_ payload: WatchCapturePayload) {
        guard session.activationState == .activated else {
            held.append(payload)
            log.notice("holding \(payload.id, privacy: .public) until activation completes")
            return
        }
        session.transferUserInfo(payload.userInfo)
        log.notice("handed \(payload.id, privacy: .public) to the outbox, coordinate: \(payload.coordinate != nil)")
    }

    /// Hands over anything ``submit(_:)`` took before the session was ready.
    private func flushHeld() {
        guard session.activationState == .activated, !held.isEmpty else { return }
        let waiting = held
        held = []
        for payload in waiting { handOver(payload) }
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
            failed: lost.count,
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
        Task { @MainActor in
            self.flushHeld()
            self.refreshStatus()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.refreshStatus() }
    }

    nonisolated func sessionCompanionAppInstalledDidChange(_ session: WCSession) {
        Task { @MainActor in self.refreshStatus() }
    }

    /// The outbox emptying is not success. A transfer that finishes *with* an error
    /// is removed from `outstandingUserInfoTransfers` exactly like a successful one
    /// and the system will not try it again, so the error is what decides.
    ///
    /// The payload comes back with the callback, which is the only reason a lost
    /// capture is recoverable at all: it is handed back to the outbox once before
    /// the wrist gives up and says so. A redelivery costs nothing, because the
    /// payload carries its own id and the phone's queue recognises one it has
    /// already stored.
    nonisolated func session(
        _ session: WCSession,
        didFinish userInfoTransfer: WCSessionUserInfoTransfer,
        error: (any Error)?
    ) {
        guard let error else {
            Task { @MainActor in self.refreshStatus() }
            return
        }

        log.error("transfer failed: \(error.localizedDescription, privacy: .public)")

        // Parsed out here, synchronously, because `[String: Any]` is not Sendable
        // and cannot cross into the Task. The payload can.
        let spent = WatchCapturePayload(userInfo: userInfoTransfer.userInfo)
        let again = spent?.retried()

        Task { @MainActor in
            guard let again else {
                // Out of budget, or the payload came back unreadable. Either way
                // this capture is gone and the wrist has to say so. Recorded under
                // the capture's own id where one survived the parse, so a
                // redelivered completion cannot inflate the count.
                self.lost.record(spent?.id ?? UUID())
                WKInterfaceDevice.current().play(.failure)
                self.refreshStatus()
                return
            }
            log.notice("re-handing \(again.id, privacy: .public), attempt \(again.attempt)")
            // Through handOver rather than straight to the session, so the retry
            // gets the same activation guard every other send has: transferUserInfo
            // raises on a session that is not activated, with nothing to catch.
            self.handOver(again)
            self.refreshStatus()
        }
    }
}
