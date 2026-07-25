// ABOUTME: The background URLSession + delegate that carries a spooled capture body to the server (SPEC 8.2).
// ABOUTME: Thin adapter over BackgroundUploadReconciler; the delegate needs a real session, so it is device-verified.

import Foundation

/// Submits capture bodies through a background `URLSession` so an upload begun by
/// one process finishes even after that process is gone (SPEC 8.2, item 6).
///
/// This is the device-verified half of the slice. The reconciliation decision it
/// makes for each finished task is the loop-tested
/// ``BackgroundUploadReconciler``; this class only owns the session, tags each
/// task with its record id, buffers the response bytes, and hands the finished
/// task to the reconciler. Keeping the untestable session wiring this thin is the
/// point.
///
/// `@unchecked Sendable`: the delegate callbacks arrive on the session's own
/// serial delegate queue, but `submit` can be called from anywhere. `session` is
/// built once in `init` (before any other reference to `self` can exist) and
/// never reassigned, so it needs no lock; the two genuinely mutable fields
/// (per-task response buffers and the stored system completion handler) are
/// guarded by ``lock``.
public final class BackgroundUploader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let reconciler: BackgroundUploadReconciler
    private let appGroup: AppGroupContainer
    private let lock = NSLock()

    /// Response bytes accumulated per task id until the task completes. A
    /// background upload's answer arrives in `didReceive` chunks, not in one
    /// piece, so they are stitched here.
    private var responseBuffers: [Int: Data] = [:]

    /// Held from `application(_:handleEventsForBackgroundURLSession:)` and fired
    /// once the session says it has delivered every queued completion, so the OS
    /// knows the relaunch is done.
    private var backgroundCompletionHandler: (@Sendable () -> Void)?

    /// Set once in `init` and never reassigned. Eager rather than lazy so two
    /// concurrent first callers cannot race a non-atomic lazy init into
    /// constructing two background sessions with the same identifier (a runtime
    /// trap). Implicitly unwrapped because the session needs `self` as its
    /// delegate, so it cannot be built until after `super.init`.
    private var session: URLSession!

    /// - Parameters:
    ///   - reconciler: the tested decision core each finished task funnels into.
    ///   - appGroup: locates the spooled request body to delete once a task
    ///     settles for good.
    ///   - identifier: the background session identifier, stable per process so a
    ///     relaunch reattaches to the same session and receives its completions.
    ///   - appGroupIdentifier: the App Group the session shares its container with.
    public init(
        reconciler: BackgroundUploadReconciler,
        appGroup: AppGroupContainer,
        identifier: String = "\(AppGroup.identifier).upload",
        appGroupIdentifier: String = AppGroup.identifier
    ) {
        self.reconciler = reconciler
        self.appGroup = appGroup
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sharedContainerIdentifier = appGroupIdentifier
        // In-app captures should confirm without waiting for the OS to decide the
        // upload is "discretionary"; the pocket case still works because a
        // suspended app's tasks run in the background regardless.
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        super.init()
        // Built here (not in a stored-property initializer) because the session
        // needs `self` as its delegate, which is only available after super.init.
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// Uploads `fileURL`'s bytes for `recordID` on the background session.
    ///
    /// The body must be a file: background sessions reject an in-memory body. The
    /// task carries the record id as its `taskDescription`, which is the only
    /// thread the delegate has back to the outbox (SPEC 8.2 reconciles by it).
    public func submit(recordID: UUID, request: URLRequest, fromFile fileURL: URL) {
        let task = session.uploadTask(with: request, fromFile: fileURL)
        task.taskDescription = recordID.uuidString
        task.resume()
    }

    /// Stores the OS completion handler from the app delegate to fire once the
    /// session finishes delivering background events.
    public func setBackgroundCompletionHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { backgroundCompletionHandler = handler }
    }

    // MARK: - URLSessionDataDelegate

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { responseBuffers[dataTask.taskIdentifier, default: Data()].append(data) }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let body = lock.withLock { responseBuffers.removeValue(forKey: task.taskIdentifier) ?? Data() }
        let completion = UploadCompletion(
            taskDescription: task.taskDescription,
            statusCode: (task.response as? HTTPURLResponse)?.statusCode,
            responseBody: body,
            transportErrorCode: (error as? URLError)?.code
        )
        let bodyFileURL = task.taskDescription
            .flatMap { UUID(uuidString: $0) }
            .map { appGroup.requestBodyFileURL(named: $0.uuidString) }
        let reconciler = self.reconciler
        Task {
            let outcome = try? await reconciler.reconcile(completion)
            // Delete the spooled envelope only when the record will not resend
            // through it. A retry or auth-hold keeps the record `pending`, and the
            // next submit rewrites this same file; deleting it here would strand
            // that resend with no body.
            // ponytail: a terminally-failed record's body file is NOT reclaimed —
            // prune() sweeps only the photo spool, not the request-body spool — so
            // it leaks one small file per dead capture. Zero impact today (nothing
            // writes these files until the submit switchover). When that lands, add
            // a requestBodySpool sweep to CaptureQueue.prune keyed on the record id.
            switch outcome {
            case .succeeded, .ignoredAlreadySettled:
                if let bodyFileURL { try? FileManager.default.removeItem(at: bodyFileURL) }
            case .failed, .ignoredUnknownTask, .none:
                break
            }
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = lock.withLock {
            let handler = backgroundCompletionHandler
            backgroundCompletionHandler = nil
            return handler
        }
        // The OS requires this on the main thread.
        if let handler {
            DispatchQueue.main.async(execute: handler)
        }
    }
}
