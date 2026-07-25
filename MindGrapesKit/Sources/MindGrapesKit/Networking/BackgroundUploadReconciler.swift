// ABOUTME: Maps one background-URLSession upload completion onto a CaptureQueue outcome (SPEC 8.2).
// ABOUTME: The tested core of item 6; the URLSession delegate is a thin adapter that calls this.

import Foundation

/// A completion event lifted out of the `URLSession` background delegate.
///
/// The delegate cannot be unit-tested (it needs a real background session), so
/// the reconciliation decision is pulled into this value plus
/// ``BackgroundUploadReconciler`` and tested against synthesized events. The
/// delegate's only job is to fill this in from `task.taskDescription`,
/// `task.response`, the bytes it accumulated, and `task`'s error.
public struct UploadCompletion: Sendable, Equatable {
    /// The `CaptureRecord.id` the submitting process stamped on the task, or `nil`
    /// if the task carried no description (nothing this app submitted should, so a
    /// `nil` is an unknown task the reconciler ignores).
    public let taskDescription: String?

    /// The HTTP status, or `nil` when the task produced no HTTP response at all
    /// (which, with no transport error either, is treated as a malformed answer).
    public let statusCode: Int?

    /// The accumulated response body. Empty is fine for a failure; a success must
    /// carry a decodable `experience_id`.
    public let responseBody: Data

    /// Set when the task failed below HTTP: no route, timeout, TLS. Retryable.
    public let transportErrorCode: URLError.Code?

    public init(
        taskDescription: String?,
        statusCode: Int?,
        responseBody: Data = Data(),
        transportErrorCode: URLError.Code? = nil
    ) {
        self.taskDescription = taskDescription
        self.statusCode = statusCode
        self.responseBody = responseBody
        self.transportErrorCode = transportErrorCode
    }
}

/// What a reconciliation did, so a caller (and a test) can see the decision
/// without re-reading the queue.
public enum ReconcileOutcome: Sendable, Equatable {
    /// Marked delivered with this `experience_id`.
    case succeeded(String)
    /// Marked failed; the string is the stable `lastErrorCode` the row will show.
    case failed(String)
    /// No task description, or no record for it (SPEC 8.2: a completion for a
    /// record this process did not submit, and never enqueued, is a no-op).
    case ignoredUnknownTask
    /// The record already settled (delivered, terminally failed, or parked for
    /// auth). A late or duplicate completion never disturbs it (SPEC 8.2).
    case ignoredAlreadySettled
}

/// Reconciles background-session upload completions against the outbox.
///
/// Every branch funnels into the same ``CaptureQueue`` mutations the foreground
/// ``CaptureDrainer`` uses, classifying the HTTP status through
/// ``BrainClient/error(forStatus:)`` so both paths agree byte-for-byte on what a
/// `413` or a `502` means. The delegate hands each finished task here; this
/// decides delivered / retry / terminal / no-op.
public struct BackgroundUploadReconciler: Sendable {
    private let queue: CaptureQueue

    public init(queue: CaptureQueue) {
        self.queue = queue
    }

    /// Applies one completion to the outbox and reports what it did.
    ///
    /// The no-op cases come first and touch nothing: an unknown or untagged task,
    /// and a record that already settled. Only a record still in play (`inFlight`,
    /// or `pending` after a crash reclaim reset the task this process did not
    /// submit) is acted on, so a duplicate success or a cross-process completion
    /// cannot resurrect a delivered or failed capture.
    @discardableResult
    public func reconcile(_ completion: UploadCompletion, now: Date = Date()) async throws -> ReconcileOutcome {
        guard let idString = completion.taskDescription,
              let id = UUID(uuidString: idString),
              let snapshot = try await queue.snapshot(id: id)
        else {
            return .ignoredUnknownTask
        }

        switch snapshot.state {
        case .succeeded, .failed, .authRequired:
            return .ignoredAlreadySettled
        case .pending, .inFlight:
            break
        }

        if let code = completion.transportErrorCode {
            let error = BrainClientError.transport(code)
            try await queue.markFailed(id: id, error: error, now: now)
            return .failed(error.code)
        }

        guard let status = completion.statusCode else {
            // A finished task with neither an HTTP response nor a transport error
            // is not something the contract describes; treat it as a malformed
            // answer (terminal) rather than guess it succeeded.
            try await queue.markFailed(id: id, error: .malformedResponse, now: now)
            return .failed(BrainClientError.malformedResponse.code)
        }

        if let error = BrainClient.error(forStatus: status) {
            try await queue.markFailed(id: id, error: error, now: now)
            return .failed(error.code)
        }

        // 2xx: the identifier the response carries is what lets us mark delivered.
        // A success status with an undecodable body is a failure for the same
        // reason it is in `BrainClient.decode` — there is no id to store.
        guard let experienceID = Self.experienceID(from: completion.responseBody) else {
            try await queue.markFailed(id: id, error: .malformedResponse, now: now)
            return .failed(BrainClientError.malformedResponse.code)
        }

        try await queue.markSucceeded(id: id, experienceID: experienceID)
        return .succeeded(experienceID)
    }

    /// Both capture doors answer with `experience_id`; the image door adds more,
    /// but reconciliation needs only the id. One envelope decodes either.
    private struct ExperienceEnvelope: Decodable {
        let experienceID: String
        enum CodingKeys: String, CodingKey { case experienceID = "experience_id" }
    }

    private static func experienceID(from body: Data) -> String? {
        try? JSONDecoder().decode(ExperienceEnvelope.self, from: body).experienceID
    }
}
