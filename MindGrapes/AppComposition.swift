// ABOUTME: Builds the capture pipeline (queue, transport, drainer, intent runner) from the onboarded server.
// ABOUTME: One process-wide instance, built with no network call, so app and Siri share a queue and refresher.

import Foundation
import MindGrapesKit
import SwiftData

/// The one place the capture object graph is assembled, shared by the capture
/// screen and the App Intents so an intent run from Siri targets the same queue,
/// store, refresher, and server as the app.
///
/// **One instance per process, cached.** A fresh graph per call would build a
/// second `ModelContainer` over the same store — concurrent construction segfaults
/// CoreData (SPEC 4.3) — and a second `CaptureQueue`, whose separate drain gate
/// would let the app and a Siri capture drain the same record twice and
/// double-deliver it (the server does not honor `idempotency_key` yet). It would
/// also build a second `AuthManager`, breaking the single-refresher rule that
/// keeps refresh-token rotation from tripping family revocation (SPEC 5.4). One
/// cached composition gives one container, one queue, one refresher.
///
/// **No network in the build, deliberately.** OAuth discovery is deferred into
/// the drainer's token closure (``LazyTokenProvider``), because the durable
/// enqueue must not depend on connectivity: an offline capture has to reach the
/// disk-backed queue even when discovery would fail (SPEC 7.1, 8.1).
///
/// ponytail: keyed on nothing, so a mid-session re-onboarding to a different
/// server keeps the first server's composition. There is no re-onboard flow yet;
/// clear the cache when Slice 7 adds "sign out / change server".
struct AppComposition: Sendable {
    let queue: CaptureQueue
    let drainer: CaptureDrainer
    let runner: CaptureIntentRunner

    enum CompositionError: Error { case notOnboarded }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: AppComposition?

    /// Returns the shared composition, building it once. Throws only on local
    /// failures: not onboarded (``CompositionError/notOnboarded``), or the App
    /// Group / store cannot be opened. A failed build is not cached, so a later
    /// call after sign-in succeeds.
    static func make() throws -> AppComposition {
        try lock.withLock {
            if let cached { return cached }
            let composition = try build()
            cached = composition
            return composition
        }
    }

    private static func build() throws -> AppComposition {
        guard let config = SharedDefaults(appGroup: AppGroup.identifier)?.serverConfig else {
            throw CompositionError.notOnboarded
        }
        let appGroup = try AppGroupContainer()
        try appGroup.prepareDirectories()
        let container = try ModelContainer(
            for: CaptureRecord.self,
            configurations: ModelConfiguration(url: appGroup.storeURL)
        )
        let queue = CaptureQueue(container: container, appGroup: appGroup)

        let tokens = LazyTokenProvider(config: config)
        let client = BrainClient(config: config, session: .shared)
        let drainer = CaptureDrainer(queue: queue, client: client) { try await tokens.validAccessToken() }
        let runner = CaptureIntentRunner(queue: queue, drainer: drainer, appGroup: appGroup)
        return AppComposition(queue: queue, drainer: drainer, runner: runner)
    }
}

/// Discovers OAuth metadata and builds the `AuthManager` on first use, then
/// reuses it — with single-flight, so concurrent first callers share one
/// discovery and one `AuthManager`.
///
/// Deferring discovery keeps ``AppComposition/build()`` off the network: offline,
/// the first `validAccessToken()` throws, the drain aborts, and the record stays
/// queued rather than lost. Single-flight matters because two `AuthManager`s
/// refreshing the same rotating refresh token would trip family revocation and
/// silently sign the user out (SPEC 5.4); one shared provider with one in-flight
/// build guarantees exactly one refresher.
///
/// ponytail: `accessGroup: nil` matches the capture screen (issue 10's -34018
/// fix); the shared keychain group returns with the extension in Slice 5.
private actor LazyTokenProvider {
    private let config: ServerConfig
    private var auth: AuthManager?
    private var building: Task<AuthManager, Error>?

    init(config: ServerConfig) { self.config = config }

    func validAccessToken() async throws -> String {
        try await resolvedAuth().validAccessToken()
    }

    /// The one `AuthManager`, built at most once even under concurrent callers.
    private func resolvedAuth() async throws -> AuthManager {
        if let auth { return auth }
        if let building { return try await building.value }

        let config = self.config
        let task = Task<AuthManager, Error> {
            let metadata = try await AuthManager.discoverMetadata(baseURL: config.baseURL, session: .shared)
            return AuthManager(session: .shared, store: TokenStore(accessGroup: nil), metadata: metadata)
        }
        building = task
        do {
            let manager = try await task.value
            auth = manager
            building = nil
            return manager
        } catch {
            // Leave auth nil so the next call retries discovery instead of caching
            // a failure (an offline first attempt must not poison later ones).
            building = nil
            throw error
        }
    }
}
