// ABOUTME: The pipeline behind the capture App Intents: validate, enqueue, attempt one bounded upload, report.
// ABOUTME: Kept in the kit and dependency-injected so perform() outcomes test off-device (SPEC 4.1, 7.1).

import Foundation

/// What one capture attempt resolved to, in the terms an intent turns into a
/// spoken or shown phrase.
///
/// SPEC 7.1: the result never depends on the round-trip completing. A durable
/// record that has not confirmed yet is a success (``queued``), because the
/// capture is safe on disk and the queue will deliver it.
public enum CaptureOutcome: Sendable, Equatable {
    /// Nothing usable was captured (empty note, or an image that will not decode).
    /// The `reason` is a short stable code, not a user string.
    case rejected(reason: String)
    /// Delivered and confirmed within the budget; carries the server id.
    case confirmed(experienceID: String)
    /// Durable and will sync: enqueued, but not confirmed within the upload budget
    /// (offline, slow, or backed off). Still a success.
    case queued
}

/// Runs a capture end to end for an App Intent.
///
/// The intent layer (app target) builds one of these from the app's composition
/// and calls a method; all the branching that decides the outcome lives here,
/// where a test drives it with a real ``CaptureQueue`` and a stubbed transport.
///
/// The first upload is attempted under ``uploadBudget`` and never blocks past it
/// (SPEC 7.1's "Saved." vs "Saved, will sync."): the drain races a timeout, and
/// on timeout the still-in-flight record is left for the queue to finish later.
public struct CaptureIntentRunner: Sendable {
    private let queue: CaptureQueue
    private let drainer: CaptureDrainer
    private let appGroup: AppGroupContainer
    private let uploadBudget: Duration

    public init(
        queue: CaptureQueue,
        drainer: CaptureDrainer,
        appGroup: AppGroupContainer,
        uploadBudget: Duration = .seconds(10)
    ) {
        self.queue = queue
        self.drainer = drainer
        self.appGroup = appGroup
        self.uploadBudget = uploadBudget
    }

    /// Captures a note: reject empty, enqueue durably, attempt one bounded upload.
    public func captureNote(
        _ content: String,
        location: LocationFix? = nil,
        now: Date = Date()
    ) async -> CaptureOutcome {
        guard let draft = NoteDraft(
            content: content, occurredAt: now,
            coordinate: location?.coordinate, placeLabel: location?.placeLabel
        ) else {
            return .rejected(reason: "empty")
        }
        do {
            let enqueued = try await queue.enqueue(note: draft, now: now)
            return await settle(id: enqueued.id, now: now)
        } catch {
            // Enqueue is the durable write; if it throws, nothing was saved.
            return .rejected(reason: "save_failed")
        }
    }

    /// Captures a photo: spool the derivative, reject undecodable bytes, enqueue
    /// durably, attempt one bounded upload. The description falls back to the
    /// timestamp template when the caller supplies none (SPEC 7.3).
    public func capturePhoto(
        _ imageData: Data,
        description: String? = nil,
        location: LocationFix? = nil,
        now: Date = Date()
    ) async -> CaptureOutcome {
        let filename: String
        do {
            filename = try PhotoSpooler.spool(imageData, into: appGroup)
        } catch {
            return .rejected(reason: "bad_image")
        }
        let text = description?.nonBlank ?? PhotoDescription.template(occurredAt: now)
        guard let draft = PhotoDraft(
            imageFilename: filename, description: text, occurredAt: now,
            coordinate: location?.coordinate, placeLabel: location?.placeLabel
        ) else {
            return .rejected(reason: "bad_image")
        }
        do {
            let enqueued = try await queue.enqueue(photo: draft, now: now)
            return await settle(id: enqueued.id, now: now)
        } catch {
            return .rejected(reason: "save_failed")
        }
    }

    /// Attempts one bounded upload, then reports what the record settled to.
    private func settle(id: UUID, now: Date) async -> CaptureOutcome {
        let snapshot = await drainWithinBudget(id: id, now: now)
        if let snapshot, snapshot.state == .succeeded, let experienceID = snapshot.experienceID {
            return .confirmed(experienceID: experienceID)
        }
        return .queued
    }

    /// Runs one drain pass, abandoning the wait (not the record) once the budget
    /// elapses. The drain's network call is cancellation-aware, so cancelling the
    /// timed-out child frees this promptly; the record is left for the queue's
    /// next pass. Returns the record's snapshot after the attempt.
    private func drainWithinBudget(id: UUID, now: Date) async -> CaptureSnapshot? {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = try? await drainer.drainOnce(now: now) }
            group.addTask { try? await Task.sleep(for: uploadBudget) }
            await group.next()
            group.cancelAll()
        }
        return try? await queue.snapshot(id: id)
    }
}
