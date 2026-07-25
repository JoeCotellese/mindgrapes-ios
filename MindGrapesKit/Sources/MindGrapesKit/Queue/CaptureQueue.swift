// ABOUTME: The actor that owns every CaptureRecord mutation and the retry state machine.
// ABOUTME: SPEC 8: durable-before-send, backoff with jitter, crash recovery, auth parking.

import Foundation
import SwiftData

/// The single writer for the capture outbox (SPEC 8.1, 8.3, 8.5).
///
/// All `CaptureRecord` mutation happens here so the not-`Sendable` model never
/// leaves one isolation domain. Callers enqueue `Sendable` drafts and read
/// ``CaptureSnapshot`` values; the transport (item 6) reports outcomes back
/// through ``markSucceeded(id:experienceID:)`` and
/// ``markFailed(id:error:now:)``.
public actor CaptureQueue {
    private let context: ModelContext
    private let appGroup: AppGroupContainer
    private var rng: any RandomNumberGenerator

    /// Succeeded records live this long so they can back the recent-captures
    /// list (SPEC 8.1) before ``prune(now:)`` removes them.
    private let retention: TimeInterval = 7 * 24 * 60 * 60

    /// - Parameters:
    ///   - container: the SwiftData store, opened once per process.
    ///   - appGroup: locates the photo spool so succeeded and pruned records can
    ///     delete their derivative.
    ///   - rng: the jitter source. Injected so backoff bounds are testable with a
    ///     seeded generator; production uses the system source.
    public init(
        container: ModelContainer,
        appGroup: AppGroupContainer,
        rng: sending any RandomNumberGenerator = SystemRandomNumberGenerator()
    ) {
        self.context = ModelContext(container)
        self.appGroup = appGroup
        self.rng = rng
    }

    // MARK: - Enqueue

    /// Persists a note capture as `pending` and due immediately (SPEC 8.4). The
    /// record is durable before this returns, so a crash before the first upload
    /// loses nothing.
    @discardableResult
    public func enqueue(note: NoteDraft, now: Date = Date()) throws -> CaptureSnapshot {
        try insert(CaptureRecord(note: note, createdAt: now))
    }

    /// Persists a photo capture as `pending` and due immediately (SPEC 8.4).
    @discardableResult
    public func enqueue(photo: PhotoDraft, now: Date = Date()) throws -> CaptureSnapshot {
        try insert(CaptureRecord(photo: photo, createdAt: now))
    }

    private func insert(_ record: CaptureRecord) throws -> CaptureSnapshot {
        context.insert(record)
        try context.save()
        return CaptureSnapshot(record)
    }

    // MARK: - Drain serialization

    /// Held for the length of one ``CaptureDrainer`` pass. That pass spans several
    /// `await`s, so the actor serializing each *call* is not enough on its own:
    /// two overlapping passes would each run ``recoverInterrupted(now:)`` and
    /// reset the other's legitimately `inFlight` records back to `pending`, then
    /// re-claim and re-send them. The server dedupes on `idempotency_key`, but
    /// the retry accounting (`attemptCount`, backoff) would still drift. One
    /// drain at a time removes the overlap instead of tolerating it.
    private var isDraining = false

    /// Claims the single drain slot for a pass, or returns `false` when one is
    /// already running so the caller can no-op. Pair every `true` with
    /// ``endDrain()``.
    func beginDrain() -> Bool {
        if isDraining { return false }
        isDraining = true
        return true
    }

    /// Releases the drain slot. Safe to call after a failed pass.
    func endDrain() { isDraining = false }

    // MARK: - Draining

    /// Claims every record that is due to send: `pending` with `nextAttemptAt`
    /// at or before `now`, oldest first. Each is marked `inFlight` and saved, so
    /// a crash mid-send leaves a record ``recoverInterrupted()`` can reclaim.
    public func claimDue(now: Date = Date()) throws -> [CaptureSnapshot] {
        let pendingRaw = CaptureState.pending.rawValue
        let descriptor = FetchDescriptor<CaptureRecord>(
            predicate: #Predicate { $0.stateRaw == pendingRaw && $0.nextAttemptAt <= now },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        let due = try context.fetch(descriptor)
        for record in due { record.state = .inFlight }
        try context.save()
        return due.map(CaptureSnapshot.init)
    }

    // MARK: - Outcomes

    /// Marks a record delivered: keep the `experience_id`, drop the spool file,
    /// clear the last error (SPEC 8.1).
    ///
    /// Guarded symmetrically with ``markFailed(id:error:now:)`` and
    /// ``markUnsendable(id:code:)`` (SPEC 8.2): a record already delivered or
    /// terminally failed is never disturbed by a late, duplicate, or
    /// cross-process completion, so two background tasks racing the same record
    /// resolve first-writer-wins rather than flipping the stored `experience_id`,
    /// and a stray success never resurrects a `.failed` record. A record still
    /// parked in `.authRequired` *is* allowed through: a capture whose upload
    /// actually landed before an unrelated refresh parked the queue is recorded
    /// delivered instead of being dropped and re-sent (a duplicate the server
    /// cannot yet dedupe). No-op if the id is unknown.
    public func markSucceeded(id: UUID, experienceID: String) throws {
        guard let record = try record(id: id) else { return }
        guard record.state != .succeeded, record.state != .failed else { return }
        record.state = .succeeded
        record.experienceID = experienceID
        record.lastErrorCode = nil
        deleteSpoolFile(for: record)
        try context.save()
    }

    /// Applies the retry policy for a failed attempt (SPEC 8.3), classifying by
    /// the error's disposition rather than its status:
    /// - `terminal`: `failed`, kept visible with its error.
    /// - `retry`: `pending`, `attemptCount` bumped, `nextAttemptAt` pushed out by
    ///   the jittered backoff.
    /// - `authRequired`: a lone `401`. Held `pending` and due now for the
    ///   refresh-and-retry cycle (section 5.4); it does not park or back off. A
    ///   failed refresh is what calls ``parkForAuth()``.
    ///
    /// No-op if the id is unknown.
    public func markFailed(id: UUID, error: BrainClientError, now: Date = Date()) throws {
        guard let record = try record(id: id) else { return }
        // A delivered capture is not un-delivered, a terminal failure not
        // resurrected, and a parked record not un-parked, by a late or duplicate
        // completion. SPEC 8.2 runs foreground and background uploads for the same
        // record, so a success and a failure can both arrive, in either order; only
        // a record still in play (inFlight, or pending awaiting its next attempt)
        // may be failed.
        guard record.state == .inFlight || record.state == .pending else { return }
        record.lastErrorCode = error.code
        switch error.retryDisposition {
        case .terminal:
            record.state = .failed
        case .authRequired:
            record.state = .pending
            record.nextAttemptAt = now
        case .retry:
            record.attemptCount += 1
            record.nextAttemptAt = now.addingTimeInterval(backoffDelay(attempt: record.attemptCount))
            record.state = .pending
        }
        try context.save()
    }

    /// Fails a record that can never be sent as-is: its body could not be
    /// encoded (a photo whose spool file vanished, say). Terminal, kept visible
    /// with its error like any other ``markFailed`` terminal outcome.
    ///
    /// Separate from ``markFailed(id:error:now:)`` because this is a client-side
    /// encoding failure, not a server ``BrainClientError``; the guard against
    /// resurrecting a settled record is the same. No-op if the id is unknown.
    public func markUnsendable(id: UUID, code: String) throws {
        guard let record = try record(id: id) else { return }
        guard record.state == .inFlight || record.state == .pending else { return }
        record.state = .failed
        record.lastErrorCode = code
        try context.save()
    }

    /// Upgrades a still-pending photo's description and OCR text after the
    /// on-device understanding finishes (Slice 6).
    ///
    /// ``CaptureIntentRunner`` enqueues the photo durably with a provisional
    /// description *before* running OCR and the on-device model, so a kill or an
    /// intent time-limit during that slow work costs only the smart description,
    /// never the capture. This applies the upgrade once the work returns.
    ///
    /// Guarded to `pending`: if a drain already claimed the record (`inFlight`) or
    /// it settled, the provisional description was already encoded and re-sending
    /// is the queue's job, not this. No-op if the id is unknown, the record is not
    /// a photo, or the new description is blank — the description field must never
    /// go empty (SPEC 11's on-box-vision switch).
    public func updatePhotoContent(id: UUID, description: String, ocrText: String?) throws {
        guard let record = try record(id: id) else { return }
        guard record.kind == .photo, record.state == .pending else { return }
        guard let description = description.nonBlank else { return }
        record.captureDescription = description
        record.ocrText = ocrText?.nonBlank
        try context.save()
    }

    // MARK: - Auth expiry (SPEC 8.5)

    /// Parks every record that could still send (`pending` or `inFlight`) in
    /// `authRequired` when a refresh returns `invalid_grant`. Parked records are
    /// not retried and not dropped; ``resumeAfterAuth(now:)`` revives them.
    public func parkForAuth() throws {
        let pendingRaw = CaptureState.pending.rawValue
        let inFlightRaw = CaptureState.inFlight.rawValue
        let descriptor = FetchDescriptor<CaptureRecord>(
            predicate: #Predicate { $0.stateRaw == pendingRaw || $0.stateRaw == inFlightRaw }
        )
        for record in try context.fetch(descriptor) {
            record.state = .authRequired
            record.lastErrorCode = "invalid_grant"
        }
        try context.save()
    }

    /// Revives parked records after a successful re-auth: back to `pending`, due
    /// now, error cleared so it no longer reads as blocked.
    public func resumeAfterAuth(now: Date = Date()) throws {
        let authRaw = CaptureState.authRequired.rawValue
        let descriptor = FetchDescriptor<CaptureRecord>(
            predicate: #Predicate { $0.stateRaw == authRaw }
        )
        for record in try context.fetch(descriptor) {
            record.state = .pending
            record.nextAttemptAt = now
            record.lastErrorCode = nil
        }
        try context.save()
    }

    // MARK: - Lifecycle

    /// Reclaims records left `inFlight` by a process that died mid-send: back to
    /// `pending`, due now (SPEC 8.1 crash recovery). Run once at launch before
    /// the first drain.
    public func recoverInterrupted(now: Date = Date()) throws {
        let inFlightRaw = CaptureState.inFlight.rawValue
        let descriptor = FetchDescriptor<CaptureRecord>(
            predicate: #Predicate { $0.stateRaw == inFlightRaw }
        )
        for record in try context.fetch(descriptor) {
            record.state = .pending
            record.nextAttemptAt = now
        }
        try context.save()
    }

    /// Deletes settled records older than the 7-day retention window (SPEC 8.1).
    ///
    /// Both `succeeded` and `failed` are reclaimed. A succeeded record's spool
    /// file is already gone from ``markSucceeded``; a terminally `failed` photo
    /// still holds its derivative (kept visible and exportable until now, item
    /// 18), so this is also what bounds spool-disk growth from server-rejected
    /// photos — without it a `.failed` photo's ~150 KB derivative would never be
    /// reclaimed, since nothing else deletes it.
    ///
    /// ponytail: ages by `createdAt` because the model has no `succeededAt`.
    /// Captures settle within seconds of creation, so the two are the same day;
    /// add a `settledAt` field if a capture ever sits pending for a week and then
    /// settles.
    public func prune(now: Date = Date()) throws {
        let cutoff = now.addingTimeInterval(-retention)
        let succeededRaw = CaptureState.succeeded.rawValue
        let failedRaw = CaptureState.failed.rawValue
        let descriptor = FetchDescriptor<CaptureRecord>(
            predicate: #Predicate {
                ($0.stateRaw == succeededRaw || $0.stateRaw == failedRaw) && $0.createdAt < cutoff
            }
        )
        for record in try context.fetch(descriptor) {
            deleteSpoolFile(for: record)
            context.delete(record)
        }
        try context.save()
    }

    // MARK: - Wire body

    /// Encodes the `/capture/note` body for one record without the record ever
    /// leaving the actor.
    ///
    /// The drain loop (item 6) needs the wire bytes, but ``CaptureWireEncoder``
    /// takes the non-`Sendable` `CaptureRecord`, which is confined here.
    /// ``CaptureSnapshot`` deliberately carries no payload, so the encode has to
    /// happen on this side of the isolation boundary. Throws
    /// ``CaptureEncodingError/recordNotFound`` if the id is unknown (a caller
    /// racing a prune), and whatever ``CaptureWireEncoder/noteBody(for:timeZone:)``
    /// throws for a non-note or empty-content record.
    public func noteBody(id: UUID, timeZone: TimeZone = .current) throws -> Data {
        guard let record = try record(id: id) else {
            throw CaptureEncodingError.recordNotFound(id)
        }
        return try CaptureWireEncoder.noteBody(for: record, timeZone: timeZone)
    }

    /// Encodes the `/capture/image` multipart body for one record, reading the
    /// spooled derivative the record names.
    ///
    /// The record and the spool bytes both stay on this side of the actor
    /// boundary, mirroring ``noteBody(id:timeZone:)``.
    ///
    /// The read failure is split by cause so the drain can classify it:
    /// - A record naming a spool file that is **not there** throws
    ///   ``CaptureEncodingError/spoolFileMissing(_:)`` — terminal, since the
    ///   derivative cannot be rebuilt from the record.
    /// - A spool file that **exists but will not read** (a locked-device data
    ///   protection failure, say) lets `Data(contentsOf:)`'s own error propagate.
    ///   The drain treats that as transient and leaves the record reclaimable,
    ///   because the bytes are still on disk and the next pass may succeed.
    ///
    /// Both distinctions are latent while the only drain is a foreground one on an
    /// unlocked device (Slice 2), but they are what keeps Slice 5's background,
    /// possibly-locked drain from terminally failing a recoverable capture.
    public func imageMultipartBody(id: UUID, timeZone: TimeZone = .current, boundary: String? = nil) throws -> MultipartFormBody {
        guard let record = try record(id: id) else {
            throw CaptureEncodingError.recordNotFound(id)
        }
        guard let filename = record.imageFilename?.nonBlank else {
            throw CaptureEncodingError.missingImageFilename
        }
        let url = appGroup.photoSpoolFileURL(named: filename)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CaptureEncodingError.spoolFileMissing(filename)
        }
        let imageData = try Data(contentsOf: url)
        return try CaptureWireEncoder.imageMultipartBody(
            for: record, imageData: imageData, timeZone: timeZone, boundary: boundary
        )
    }

    // MARK: - Reading

    /// A snapshot of one record, or `nil` if it is gone.
    public func snapshot(id: UUID) throws -> CaptureSnapshot? {
        try record(id: id).map(CaptureSnapshot.init)
    }

    /// Every record, newest first. Backs the recent-captures list (item 18).
    public func allSnapshots() throws -> [CaptureSnapshot] {
        let descriptor = FetchDescriptor<CaptureRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try context.fetch(descriptor).map(CaptureSnapshot.init)
    }

    // MARK: - Plumbing

    private func record(id: UUID) throws -> CaptureRecord? {
        try context.fetch(
            FetchDescriptor<CaptureRecord>(predicate: #Predicate { $0.id == id })
        ).first
    }

    /// Full jitter, capped at one hour (SPEC 8.3):
    /// `delay = random(0, min(30 * 2^attempt, 3600))`.
    private func backoffDelay(attempt: Int) -> TimeInterval {
        let cap = min(30 * pow(2, Double(attempt)), 3600)
        return Double.random(in: 0...cap, using: &rng)
    }

    /// Best effort: a missing or undeletable spool file must never fail a
    /// success or a prune. The spool derivative is rebuildable; the record is not.
    private func deleteSpoolFile(for record: CaptureRecord) {
        guard let filename = record.imageFilename else { return }
        try? FileManager.default.removeItem(at: appGroup.photoSpoolFileURL(named: filename))
    }
}
