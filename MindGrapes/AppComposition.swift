// ABOUTME: Builds the capture pipeline (queue, transport, drainer, intent runner) from the onboarded server.
// ABOUTME: Constructed with no network call, so an offline capture still enqueues durably before any drain.

import Foundation
import MindGrapesKit
import SwiftData

/// The one place the capture object graph is assembled, shared by the capture
/// screen and the App Intents so an intent run from Siri targets the same queue,
/// store, and server as the app.
///
/// **No network in the initializer, deliberately.** OAuth discovery is deferred
/// into the drainer's token closure (``LazyTokenProvider``), because the durable
/// enqueue must not depend on connectivity: an offline capture has to reach the
/// disk-backed queue even when discovery would fail. Only the drain needs the
/// network, and a failed drain leaves the record durable (SPEC 7.1, 8.1).
struct AppComposition {
    let queue: CaptureQueue
    let drainer: CaptureDrainer
    let runner: CaptureIntentRunner

    enum CompositionError: Error { case notOnboarded }

    /// Builds the graph from the persisted server config. Throws only on local
    /// failures: not onboarded, or the App Group / store cannot be opened.
    static func make() throws -> AppComposition {
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
/// reuses it. Deferring discovery is what keeps ``AppComposition.make()`` off the
/// network: if the device is offline, the first `validAccessToken()` throws, the
/// drain aborts, and the record stays queued rather than lost.
///
/// ponytail: `accessGroup: nil` matches the capture screen (issue 10's -34018
/// fix); the shared keychain group returns with the extension in Slice 5.
private actor LazyTokenProvider {
    private let config: ServerConfig
    private var auth: AuthManager?

    init(config: ServerConfig) { self.config = config }

    func validAccessToken() async throws -> String {
        if auth == nil {
            let metadata = try await AuthManager.discoverMetadata(baseURL: config.baseURL, session: .shared)
            auth = AuthManager(session: .shared, store: TokenStore(accessGroup: nil), metadata: metadata)
        }
        return try await auth!.validAccessToken()
    }
}
