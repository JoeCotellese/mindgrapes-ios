// ABOUTME: App delegate that drains the outbox when connectivity returns (SPEC 8.2 success condition 4).
// ABOUTME: Owns the app-lifetime NWPathMonitor; the background-session launch-event wiring lands with the HITL switchover.

import MindGrapesKit
import UIKit

/// Starts the connectivity-driven drain for the app's lifetime.
///
/// A capture made offline sits durable in the queue; this turns "network came
/// back" into an immediate foreground drain rather than a wait, which is exactly
/// success condition 4 for the case where the app is still alive. The
/// kill-mid-upload case (condition 5) rides the background `URLSession` instead,
/// whose `handleEventsForBackgroundURLSession` wiring lands with the device-
/// verified switchover that routes captures through that session.
final class MindGrapesAppDelegate: NSObject, UIApplicationDelegate {
    private var pathTrigger: NetworkPathTrigger?
    private let watchSession = WatchSessionCoordinator.shared

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // At launch, not on first appearance of a screen. The system delivers a
        // queued watch handoff only to an app that has activated a session, and it
        // may launch this app in the background purely to do it — at which point no
        // screen ever appears (SPEC Decision 5).
        watchSession.activate()
        let trigger = NetworkPathTrigger {
            // Resolve the composition lazily: at launch the user may not be
            // onboarded, in which case there is nothing to drain and make() throws
            // harmlessly. drainOnce no-ops when nothing is due.
            Task {
                guard let composition = try? AppComposition.make() else { return }
                _ = try? await composition.drainer.drainOnce()
            }
        }
        trigger.start()
        pathTrigger = trigger
        return true
    }

    /// Re-pushes the location toggle to the wrist. Cheap, latest-value-wins, and it
    /// is what makes a toggle the user changed in Settings reach the Watch without
    /// waiting for the next cold launch.
    func applicationDidBecomeActive(_ application: UIApplication) {
        watchSession.pushSettings()
    }
}
