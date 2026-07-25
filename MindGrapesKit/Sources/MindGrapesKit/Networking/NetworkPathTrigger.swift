// ABOUTME: Fires a drain when connectivity returns, so a pocket-queued capture leaves on reconnect (item 6).
// ABOUTME: A thin NWPathMonitor seam; the real path transitions are device/sim behavior, not loop-tested.

import Foundation
import Network

/// Watches the network path and fires once each time connectivity is *regained*.
///
/// The background session already retries on its own schedule; this is the nudge
/// that turns "airplane mode off" into an immediate drain rather than a wait
/// (SPEC 8.2 success condition 4). It fires on the transition into `.satisfied`,
/// not on every update, so a flaky link does not spam the drain.
///
/// `@unchecked Sendable`: `NWPathMonitor` delivers updates on its own queue while
/// `start`/`cancel` may be called from elsewhere; the one bit of shared state
/// (the last satisfied-ness) is guarded by ``lock``.
public final class NetworkPathTrigger: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "\(AppGroup.identifier).networkpath")
    private let onReconnect: @Sendable () -> Void
    private let lock = NSLock()
    private var wasSatisfied = false
    private var started = false

    /// - Parameter onReconnect: run when the path becomes satisfied after not
    ///   being. Typically kicks a drain / resubmit. Called on the monitor's queue.
    public init(onReconnect: @escaping @Sendable () -> Void) {
        self.onReconnect = onReconnect
    }

    /// Begins watching. The first satisfied path after start counts as a regain,
    /// so a capture made offline that then finds a live path on launch still
    /// drains. Idempotent.
    public func start() {
        let shouldStart = lock.withLock {
            if started { return false }
            started = true
            return true
        }
        guard shouldStart else { return }

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = path.status == .satisfied
            let fire = lock.withLock {
                let regained = satisfied && !wasSatisfied
                wasSatisfied = satisfied
                return regained
            }
            if fire { onReconnect() }
        }
        monitor.start(queue: queue)
    }

    public func cancel() {
        monitor.cancel()
        // Reset so a later start() rewatches instead of no-opping on the stale
        // `started` flag.
        lock.withLock {
            started = false
            wasSatisfied = false
        }
    }
}
