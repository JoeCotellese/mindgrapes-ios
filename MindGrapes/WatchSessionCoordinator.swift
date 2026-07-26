// ABOUTME: The phone's WCSession delegate: takes a watch handoff and gives it to WatchCaptureReceiver.
// ABOUTME: Session wiring only; every decision about the capture lives in the kit, where it is tested.

import Foundation
import MindGrapesKit
import OSLog
import UIKit
import WatchConnectivity

private let log = Logger(subsystem: "net.cotellese.mindgrapes", category: "watch-receive")

/// Receives captures the Watch handed to the system outbox (SPEC Decision 5, 8.1).
///
/// Activated at launch, not lazily, and that is load-bearing: the system delivers a
/// queued transfer only to an app that has activated a session, and it may launch
/// this app in the background to do it. An app that activated its session on first
/// appearance of some screen would never receive a handoff made while it was closed.
///
/// Deliberately thin. Everything it decides is ``WatchCaptureReceiver``'s, which is
/// tested in the kit; the app target has no test target (#24). Same split as
/// `BackgroundUploader` over `BackgroundUploadReconciler`.
final class WatchSessionCoordinator: NSObject, @unchecked Sendable {
    private let session: WCSession

    init(session: WCSession = .default) {
        self.session = session
        super.init()
    }

    /// No-op on a device with no Watch support (every iPad, and the simulator's
    /// unpaired phones), so the caller can wire this unconditionally.
    func activate() {
        guard WCSession.isSupported() else { return }
        session.delegate = self
        session.activate()
    }

    /// Tells the wrist whether the user wants captures located.
    ///
    /// `updateApplicationContext` is latest-value-wins with no queue, which is
    /// exactly a setting's semantics, and the system holds the last value for the
    /// counterpart to read whenever it next runs. That is why the Watch needs no
    /// storage of its own for this.
    ///
    /// The toggle lives in App Group `UserDefaults` that the Watch cannot read, and
    /// the wrist must not prompt for a permission the user already declined on the
    /// phone, so it has to be pushed rather than looked up.
    func pushSettings() {
        guard session.activationState == .activated else { return }
        let includeLocation = SharedDefaults()?.includeLocation ?? false
        do {
            try session.updateApplicationContext(["includeLocation": includeLocation])
        } catch {
            // Non-fatal: the wrist falls back to taking no location, which is the
            // conservative direction.
            log.error("could not push settings to the watch: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - WCSessionDelegate

extension WatchSessionCoordinator: WCSessionDelegate {
    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        if let error {
            log.error("activation failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        pushSettings()
    }

    /// One handoff, one capture.
    ///
    /// Once this returns the system considers the transfer delivered and will not
    /// offer it again, so the work that makes the capture durable has to survive
    /// past the return. The system may have launched this app in the background
    /// purely to deliver the handoff, in which case the process becomes eligible
    /// for suspension as soon as the runloop goes quiet — before the enqueue below
    /// has reached disk. The background-task assertion is what keeps it alive, and
    /// it covers the drain too: a drain that dies mid-flight leaves the record
    /// queued rather than lost, but a suspension before `save()` loses the capture
    /// outright with nothing to retry from.
    ///
    /// The assertion is taken on the main actor because `UIApplication` requires
    /// it, which leaves one runloop hop between this return and the assertion
    /// being held. That gap is not closable from a delegate callback that arrives
    /// off the main actor, and a scheduled Task starts long before the system
    /// quiesces a process, so it is the residual rather than the risk.
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        // Parsed here, synchronously, because `[String: Any]` is not Sendable and so
        // cannot cross into the Task. The payload can.
        guard let payload = WatchCapturePayload(userInfo: userInfo) else {
            log.error("rejected watch capture: malformed_payload")
            return
        }

        Task { @MainActor in
            let assertion = UIApplication.shared.beginBackgroundTask(withName: "watch-capture")
            defer { UIApplication.shared.endBackgroundTask(assertion) }

            guard let composition = try? AppComposition.make() else {
                // Not onboarded, or the store will not open. The transfer is gone
                // either way, so this is the one place a watch capture can be lost —
                // and it can only happen before the user has ever signed in.
                log.error("received a watch capture with no composition; it is lost")
                return
            }

            // Built per receive rather than held, so a toggle the user changed since
            // launch is honoured without a restart.
            let geocoder: (any ReverseGeocoding)? =
                SharedDefaults()?.includeLocation == true ? SystemReverseGeocoder() : nil

            let outcome = await WatchCaptureReceiver(
                queue: composition.queue,
                geocoder: geocoder
            ).receive(payload)

            switch outcome {
            case .enqueued(let id):
                log.notice("enqueued watch capture \(id, privacy: .public)")
                _ = try? await composition.drainer.drainOnce()
            case .duplicate(let id):
                log.notice("watch capture \(id, privacy: .public) was already queued; redelivery ignored")
            case .rejected(let reason):
                log.error("rejected watch capture: \(reason, privacy: .public)")
            }
        }
    }

    // Required on iOS. Both mean the pairing changed under us; the next activation
    // re-pushes settings, and nothing here holds per-Watch state to tear down.
    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // Reactivate so a switched Watch can still hand captures over.
        session.activate()
    }
}
