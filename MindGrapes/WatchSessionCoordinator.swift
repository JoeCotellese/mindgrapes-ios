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
    /// The one coordinator, so a screen that changes a setting the Watch depends
    /// on can push it without owning the session.
    ///
    /// A second instance would take over `WCSession.default`'s single delegate
    /// slot and silently stop the first one receiving captures, so this is not
    /// merely convenient — the type is a singleton whether or not it says so.
    /// `init` is private, because a doc comment saying "do not construct another"
    /// is not what stops anyone; the access level is.
    static let shared = WatchSessionCoordinator()

    private let session: WCSession

    private init(session: WCSession = .default) {
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
        // Through ``WatchSettings`` rather than read straight off the toggle. The
        // stored value defaults to `true` when the user has not answered the
        // location pitch yet, and pushing that unset `true` makes the watch app
        // raise a system location alert the moment it opens, unprompted (SPEC 9).
        let includeLocation = WatchSettings.includeLocation(SharedDefaults())
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

            let composition: AppComposition
            do {
                composition = try AppComposition.make()
            } catch {
                // The transfer is gone whatever went wrong here, so this is the one
                // place a watch capture can be lost outright.
                //
                // Not only the not-onboarded case, which is what this used to
                // claim. `AppComposition.make()` also throws when the App Group
                // container is unavailable, when its directories cannot be
                // prepared, or when the `ModelContainer` will not open — and a
                // phone launched in the background before its first unlock after a
                // reboot hits exactly that, with a paired Watch handing captures
                // over the whole time. The error is logged rather than swallowed
                // because it is the only evidence that will ever exist.
                log.error(
                    "watch capture \(payload.id, privacy: .public) lost, no composition: \(String(describing: error), privacy: .public)"
                )
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
                // Best-effort: the record is already durable, so a drain that fails
                // costs latency and not the capture. Logged rather than discarded
                // because a silent `try?` here is what made a real incident
                // undiagnosable — three watch captures sat queued for fifteen
                // minutes and only went out when the app was next opened, with
                // nothing in the log to say whether the drain had run and failed or
                // never run at all.
                do {
                    _ = try await composition.drainer.drainOnce()
                } catch {
                    log.error(
                        "drain after watch capture \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)"
                    )
                }
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

    /// Fires when the Watch app is installed, removed, or the paired Watch
    /// changes. A freshly installed watch app has no application context at all,
    /// so without this it would take no location until the phone next came to the
    /// foreground — and the wrist must never guess, because guessing wrong means
    /// prompting for a permission the user already declined (SPEC 9).
    func sessionWatchStateDidChange(_ session: WCSession) {
        pushSettings()
    }
}
