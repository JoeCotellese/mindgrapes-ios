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
    /// Nothing usable was captured (empty note, or an image that will not decode),
    /// so nothing was enqueued. The `reason` is a short stable code, not a user
    /// string. `"empty"` / `"bad_image"` are user-fixable input; `"save_failed"`
    /// is a durable-write failure (the capture was lost) and must not be spoken
    /// as if the input were merely empty.
    case rejected(reason: String)
    /// Delivered and confirmed within the budget; carries the server id.
    case confirmed(experienceID: String)
    /// Durable and will sync: enqueued, but not confirmed within the upload budget
    /// (offline, slow, or backed off). Still a success.
    case queued
    /// Enqueued and durable, but the server rejected it terminally within the
    /// budget (a `400`/`413`/`415`): it will not sync on its own. Not a lost
    /// capture, but not a silent "will sync" either.
    case failed
    /// Enqueued and durable, but parked because the session needs re-auth (a dead
    /// refresh). It syncs once the user signs in again; connectivity is not the issue.
    case needsSignIn
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
    private let photoUnderstanding: PhotoUnderstanding
    private let timeZone: TimeZone
    private let uploadBudget: Duration

    public init(
        queue: CaptureQueue,
        drainer: CaptureDrainer,
        appGroup: AppGroupContainer,
        photoUnderstanding: PhotoUnderstanding = PhotoUnderstanding(
            recognizer: DisabledTextRecognizer(),
            generator: TemplateOnlyDescriptionGenerator()
        ),
        timeZone: TimeZone = .current,
        uploadBudget: Duration = .seconds(10)
    ) {
        self.queue = queue
        self.drainer = drainer
        self.appGroup = appGroup
        self.photoUnderstanding = photoUnderstanding
        self.timeZone = timeZone
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
        // OCR the original bytes (higher resolution than the spooled derivative)
        // and compose the description: user words win, else the model, else the
        // template (SPEC 7.2/7.3). OCR is best-effort and never fails the capture.
        let understanding = await photoUnderstanding.understand(
            imageData: imageData, userDescription: description, occurredAt: now, timeZone: timeZone
        )
        guard let draft = PhotoDraft(
            imageFilename: filename, description: understanding.description, ocrText: understanding.ocrText,
            occurredAt: now, coordinate: location?.coordinate, placeLabel: location?.placeLabel
        ) else {
            // The derivative is spooled but no record will name it; delete it so
            // it is not orphaned (only record-backed spool files are ever reclaimed).
            deleteSpool(filename)
            return .rejected(reason: "bad_image")
        }
        do {
            let enqueued = try await queue.enqueue(photo: draft, now: now)
            return await settle(id: enqueued.id, now: now)
        } catch {
            deleteSpool(filename)
            return .rejected(reason: "save_failed")
        }
    }

    /// Attempts one bounded upload, then reports what the record settled to.
    ///
    /// A record that reaches a terminal `.failed` or a parked `.authRequired`
    /// within the budget is reported as such rather than as `.queued`, so the
    /// caller does not tell the user "it'll sync" about a capture that will not.
    private func settle(id: UUID, now: Date) async -> CaptureOutcome {
        guard let snapshot = await drainWithinBudget(id: id, now: now) else { return .queued }
        switch snapshot.state {
        case .succeeded:
            return snapshot.experienceID.map(CaptureOutcome.confirmed) ?? .queued
        case .failed:
            return .failed
        case .authRequired:
            return .needsSignIn
        case .pending, .inFlight:
            return .queued
        }
    }

    /// Best-effort delete of a spooled derivative that never got a record.
    private func deleteSpool(_ filename: String) {
        try? FileManager.default.removeItem(at: appGroup.photoSpoolFileURL(named: filename))
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
