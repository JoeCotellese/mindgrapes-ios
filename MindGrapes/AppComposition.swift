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
    /// The background-session uploader (item 6). Constructed and reconciler-backed
    /// so a relaunch for `handleEventsForBackgroundURLSession` reattaches to the
    /// same session and drains its held completions. The capture call sites still
    /// deliver through ``drainer`` for now; routing them through this session is
    /// the device-verified switchover (SPEC 8.2 success condition 5).
    let uploader: BackgroundUploader

    enum CompositionError: Error { case notOnboarded }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: AppComposition?

    /// Returns the shared composition, building it once. Throws only on local
    /// failures: not onboarded (``CompositionError/notOnboarded``), or the App
    /// Group / store cannot be opened. A failed build is not cached, so a later
    /// call after sign-in succeeds.
    /// Clears the cached server/auth layer so the next ``make()`` rebuilds it.
    ///
    /// Called on sign out and on re-onboarding to a different server: the cached
    /// composition's `BrainClient` and `AuthManager` are bound to the old server's
    /// config and metadata. Nilling `cached` drops only that layer; the durable
    /// ``sharedStore`` (container, queue, uploader) is kept and never rebuilt, so
    /// this cannot construct a second `ModelContainer`. Defensive rather than
    /// load-bearing for tokens — `AuthManager` reads the Keychain live — but
    /// required so a changed server routes captures to the right host.
    static func reset() {
        lock.withLock { cached = nil }
    }

    static func make() throws -> AppComposition {
        try lock.withLock {
            if let cached { return cached }
            let composition = try build()
            cached = composition
            return composition
        }
    }

    /// The durable, user-agnostic half of the graph: the App Group container, the
    /// SwiftData store, the queue over it, and the background uploader. Built at
    /// most **once per process** and never rebuilt, because a second
    /// `ModelContainer` over the same store URL segfaults CoreData schema setup
    /// (SPEC 4.3). ``reset()`` rebuilds only the server/auth layer over these, so
    /// no sign-out / re-sign-in / re-onboard can ever construct a second container
    /// — even a capture App Intent running across a sign-out reuses this.
    private struct SharedStore {
        let appGroup: AppGroupContainer
        let queue: CaptureQueue
        let uploader: BackgroundUploader
    }

    nonisolated(unsafe) private static var sharedStore: SharedStore?

    /// Builds or returns the process-global store components. Caller holds `lock`.
    private static func sharedStoreComponents() throws -> SharedStore {
        if let sharedStore { return sharedStore }
        let appGroup = try AppGroupContainer()
        try appGroup.prepareDirectories()
        let container = try ModelContainer(
            for: CaptureRecord.self,
            configurations: ModelConfiguration(url: appGroup.storeURL)
        )
        let queue = CaptureQueue(container: container, appGroup: appGroup)
        let reconciler = BackgroundUploadReconciler(queue: queue)
        let uploader = BackgroundUploader(reconciler: reconciler, appGroup: appGroup)
        let store = SharedStore(appGroup: appGroup, queue: queue, uploader: uploader)
        sharedStore = store
        return store
    }

    private static func build() throws -> AppComposition {
        guard let config = SharedDefaults(appGroup: AppGroup.identifier)?.serverConfig else {
            throw CompositionError.notOnboarded
        }
        // Reuse the once-built store; only the server-dependent transport below is
        // rebuilt when reset() clears the cache.
        let store = try sharedStoreComponents()

        let tokens = LazyTokenProvider(config: config)
        let client = BrainClient(config: config, session: .shared)
        let drainer = CaptureDrainer(queue: store.queue, client: client) { try await tokens.validAccessToken() }
        let runner = CaptureIntentRunner(
            queue: store.queue, drainer: drainer, appGroup: store.appGroup,
            photoUnderstanding: makePhotoUnderstanding()
        )
        return AppComposition(queue: store.queue, drainer: drainer, runner: runner, uploader: store.uploader)
    }

    /// The real OCR + on-device description (Slice 6), each behind its framework
    /// gate so a build without Vision or Foundation Models falls back cleanly. On
    /// device the model is used only when Apple Intelligence reports available;
    /// otherwise the template fallback (SPEC 7.3, success condition 8) runs.
    private static func makePhotoUnderstanding() -> PhotoUnderstanding {
        #if canImport(Vision)
        let recognizer: any TextRecognizing = VisionTextRecognizer()
        #else
        let recognizer: any TextRecognizing = DisabledTextRecognizer()
        #endif

        #if canImport(FoundationModels)
        let generator: any DescriptionGenerating = FoundationModelsDescriptionGenerator()
        #else
        let generator: any DescriptionGenerating = TemplateOnlyDescriptionGenerator()
        #endif

        return PhotoUnderstanding(recognizer: recognizer, generator: generator)
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
