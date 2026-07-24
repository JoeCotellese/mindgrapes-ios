// ABOUTME: Proves the CaptureQueue state machine, backoff bounds, crash recovery, and auth parking.
// ABOUTME: Every test opens a real store, so the whole suite is serialized against the CoreData segfault.

import Foundation
import SwiftData
import Testing

@testable import MindGrapesKit

/// One store per test, and stores are built one at a time.
///
/// Concurrent `ModelContainer` construction segfaults CoreData schema setup
/// (see ``CaptureRecordTests``), so this suite is serialized for the same
/// reason: everything here opens a store.
@Suite(.serialized)
struct CaptureQueueTests {
    /// A queue over a throwaway on-disk store plus a temp App Group root for the
    /// photo spool. On-disk rather than in-memory so crash recovery and durability
    /// exercise the real store, matching ``CaptureRecordTests``.
    private final class Fixture {
        let directory: URL
        let container: ModelContainer
        let appGroup: AppGroupContainer

        init() throws {
            directory = URL.temporaryDirectory.appending(path: "MindGrapesQueueTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            container = try ModelContainer(
                for: CaptureRecord.self,
                configurations: ModelConfiguration(url: directory.appending(path: "captures.store"))
            )
            appGroup = AppGroupContainer(rootURL: directory)
            try appGroup.prepareDirectories()
        }

        func makeQueue(seed: UInt64 = 1) -> CaptureQueue {
            CaptureQueue(container: container, appGroup: appGroup, rng: SeededRandomNumberGenerator(seed: seed))
        }

        /// A separate context, the way a prior process or a test setup would write
        /// straight to the store to seed a starting state.
        func directContext() -> ModelContext { ModelContext(container) }

        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    private func note(_ content: String = "A note.") throws -> NoteDraft {
        try #require(NoteDraft(content: content))
    }

    private func photo(filename: String) throws -> PhotoDraft {
        try #require(PhotoDraft(imageFilename: filename, description: "A photo.", occurredAt: Date()))
    }

    // MARK: - Enqueue and durability

    @Test func enqueuePersistsAPendingRecordDueImmediately() async throws {
        let fixture = try Fixture()
        let queue = fixture.makeQueue()
        let now = Date(timeIntervalSince1970: 1_000_000)

        let snapshot = try await queue.enqueue(note: note(), now: now)

        #expect(snapshot.state == .pending)
        #expect(snapshot.attemptCount == 0)
        #expect(snapshot.nextAttemptAt == now)

        // Durable: a fresh context over the same store sees it.
        let persisted = try fixture.directContext().fetch(FetchDescriptor<CaptureRecord>())
        #expect(persisted.count == 1)
        #expect(persisted.first?.id == snapshot.id)
    }

    // MARK: - Draining

    @Test func claimDueReturnsDueRecordsOldestFirstAndMarksThemInFlight() async throws {
        let fixture = try Fixture()
        let queue = fixture.makeQueue()
        let base = Date(timeIntervalSince1970: 1_000_000)

        let older = try await queue.enqueue(note: note("older"), now: base)
        let newer = try await queue.enqueue(note: note("newer"), now: base.addingTimeInterval(1))

        let claimed = try await queue.claimDue(now: base.addingTimeInterval(2))

        #expect(claimed.map(\.id) == [older.id, newer.id])
        #expect(claimed.allSatisfy { $0.state == .inFlight })
        // The inFlight marking is persisted, which is what crash recovery relies on.
        let reloaded = try await queue.snapshot(id: older.id)
        #expect(reloaded?.state == .inFlight)
    }

    @Test func claimDueSkipsRecordsNotYetDue() async throws {
        let fixture = try Fixture()
        let queue = fixture.makeQueue()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let due = try await queue.enqueue(note: note("due"), now: now)

        // Fail one so it backs off into the future, then drain at the same instant.
        let future = try await queue.enqueue(note: note("later"), now: now)
        try await queue.markFailed(id: future.id, error: .badGateway, now: now)

        let claimed = try await queue.claimDue(now: now)
        #expect(claimed.map(\.id) == [due.id])
    }

    // MARK: - Success

    @Test func markSucceededKeepsExperienceIDDropsSpoolAndClearsError() async throws {
        let fixture = try Fixture()
        let queue = fixture.makeQueue()
        let spoolName = "A1B2.jpg"
        let spoolURL = fixture.appGroup.photoSpoolFileURL(named: spoolName)
        try Data("jpeg".utf8).write(to: spoolURL)

        let snapshot = try await queue.enqueue(photo: photo(filename: spoolName))
        try await queue.markFailed(id: snapshot.id, error: .badGateway)
        try await queue.markSucceeded(id: snapshot.id, experienceID: "exp-42")

        let reloaded = try #require(try await queue.snapshot(id: snapshot.id))
        #expect(reloaded.state == .succeeded)
        #expect(reloaded.experienceID == "exp-42")
        #expect(reloaded.lastErrorCode == nil)
        #expect(!FileManager.default.fileExists(atPath: spoolURL.path))
    }

    @Test func markSucceededOnUnknownIDIsANoOp() async throws {
        let fixture = try Fixture()
        let queue = fixture.makeQueue()
        // A duplicate completion for an already-reconciled record must not crash.
        try await queue.markSucceeded(id: UUID(), experienceID: "exp")
        #expect(try await queue.allSnapshots().isEmpty)
    }

    @Test func aLateFailureDoesNotUndoADeliveredCapture() async throws {
        // SPEC 8.2 double-delivery: foreground upload succeeds, then the background
        // task for the same record reports a transport error. The delivered capture
        // must not flip back to pending and re-upload.
        let fixture = try Fixture()
        let queue = fixture.makeQueue()
        let snapshot = try await queue.enqueue(note: note())

        try await queue.markSucceeded(id: snapshot.id, experienceID: "exp-7")
        try await queue.markFailed(id: snapshot.id, error: .badGateway)

        let reloaded = try #require(try await queue.snapshot(id: snapshot.id))
        #expect(reloaded.state == .succeeded)
        #expect(reloaded.experienceID == "exp-7")
        #expect(reloaded.lastErrorCode == nil)
    }

    @Test func aLateFailureDoesNotUnparkAnAuthRequiredRecord() async throws {
        // SPEC 8.5: parked records are not retried. A record's own late transport
        // failure must not pull it out of authRequired back to pending.
        let fixture = try Fixture()
        let queue = fixture.makeQueue()
        let snapshot = try await queue.enqueue(note: note())
        try await queue.parkForAuth()

        try await queue.markFailed(id: snapshot.id, error: .badGateway)

        #expect(try await queue.snapshot(id: snapshot.id)?.state == .authRequired)
    }

    // MARK: - Retry classification (one per error class from item 4)

    @Test(arguments: [
        BrainClientError.badRequest,
        .methodNotAllowed,
        .payloadTooLarge,
        .unsupportedMediaType,
        .malformedResponse,
        .unexpectedStatus(404),
    ])
    func terminalErrorsFailTheRecordAndKeepItVisible(error: BrainClientError) async throws {
        let fixture = try Fixture()
        let queue = fixture.makeQueue()
        let snapshot = try await queue.enqueue(note: note())

        try await queue.markFailed(id: snapshot.id, error: error)

        let reloaded = try #require(try await queue.snapshot(id: snapshot.id))
        #expect(reloaded.state == .failed)
        #expect(reloaded.lastErrorCode == error.code)
        #expect(reloaded.attemptCount == 0)
    }

    @Test(arguments: [
        BrainClientError.badGateway,
        .transport(.timedOut),
        .unexpectedStatus(503),
    ])
    func retryableErrorsBumpTheAttemptAndBackOff(error: BrainClientError) async throws {
        let fixture = try Fixture()
        let queue = fixture.makeQueue()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let snapshot = try await queue.enqueue(note: note(), now: now)

        try await queue.markFailed(id: snapshot.id, error: error, now: now)

        let reloaded = try #require(try await queue.snapshot(id: snapshot.id))
        #expect(reloaded.state == .pending)
        #expect(reloaded.attemptCount == 1)
        #expect(reloaded.lastErrorCode == error.code)
        #expect(reloaded.nextAttemptAt >= now)
    }

    @Test func unauthorizedHoldsPendingAndDueNowWithoutBackoff() async throws {
        let fixture = try Fixture()
        let queue = fixture.makeQueue()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let snapshot = try await queue.enqueue(note: note(), now: now)

        try await queue.markFailed(id: snapshot.id, error: .unauthorized, now: now)

        let reloaded = try #require(try await queue.snapshot(id: snapshot.id))
        #expect(reloaded.state == .pending)
        #expect(reloaded.nextAttemptAt == now)
        #expect(reloaded.attemptCount == 0)
        #expect(reloaded.lastErrorCode == "401")
    }

    // MARK: - Backoff bounds (SPEC 8.3)

    @Test func backoffStaysWithinTheJitterCapAcrossManySamples() async throws {
        let fixture = try Fixture()
        let queue = fixture.makeQueue(seed: 0xDEAD_BEEF)
        let now = Date(timeIntervalSince1970: 1_000_000)

        // Independent records, each failed once, sample attempt-1 backoff many
        // times. The cap for attempt 1 is min(30 * 2^1, 3600) = 60 seconds.
        for _ in 0..<400 {
            let snapshot = try await queue.enqueue(note: note(), now: now)
            try await queue.markFailed(id: snapshot.id, error: .badGateway, now: now)
            let reloaded = try #require(try await queue.snapshot(id: snapshot.id))
            let delay = reloaded.nextAttemptAt.timeIntervalSince(now)
            #expect(delay >= 0)
            #expect(delay <= 60)
        }
    }

    @Test func backoffCapNeverExceedsOneHourAtHighAttemptCounts() async throws {
        let fixture = try Fixture()
        let queue = fixture.makeQueue(seed: 7)
        let now = Date(timeIntervalSince1970: 1_000_000)

        // Seed a record already deep into its retries so the uncapped term
        // (30 * 2^attempt) would blow past an hour; the cap must hold it.
        let context = fixture.directContext()
        let record = CaptureRecord(note: try note(), createdAt: now)
        record.state = .inFlight
        record.attemptCount = 20
        context.insert(record)
        try context.save()

        try await queue.markFailed(id: record.id, error: .badGateway, now: now)

        let reloaded = try #require(try await queue.snapshot(id: record.id))
        let delay = reloaded.nextAttemptAt.timeIntervalSince(now)
        #expect(delay >= 0)
        #expect(delay <= 3600)
    }

    // MARK: - Crash recovery (SPEC 8.1)

    @Test func recoverInterruptedReturnsInFlightRecordsToPending() async throws {
        let fixture = try Fixture()
        let now = Date(timeIntervalSince1970: 1_000_000)

        // A prior process left a record mid-send.
        let context = fixture.directContext()
        let stranded = CaptureRecord(note: try note("mid-flight"), createdAt: now)
        stranded.state = .inFlight
        context.insert(stranded)
        try context.save()

        let queue = fixture.makeQueue()
        try await queue.recoverInterrupted(now: now.addingTimeInterval(5))

        let reloaded = try #require(try await queue.snapshot(id: stranded.id))
        #expect(reloaded.state == .pending)
        #expect(reloaded.nextAttemptAt == now.addingTimeInterval(5))
    }

    // MARK: - Auth expiry (SPEC 8.5)

    @Test func parkForAuthMovesLiveRecordsToAuthRequiredAndSkipsSettled() async throws {
        let fixture = try Fixture()
        let queue = fixture.makeQueue()
        let now = Date(timeIntervalSince1970: 1_000_000)

        let pending = try await queue.enqueue(note: note("pending"), now: now)
        let inFlight = try await queue.enqueue(note: note("inflight"), now: now)
        _ = try await queue.claimDue(now: now) // both become inFlight
        // Return one to pending so we cover both live states.
        try await queue.markFailed(id: pending.id, error: .badGateway, now: now)

        let succeeded = try await queue.enqueue(note: note("done"), now: now)
        try await queue.markSucceeded(id: succeeded.id, experienceID: "exp")
        let failed = try await queue.enqueue(note: note("dead"), now: now)
        try await queue.markFailed(id: failed.id, error: .badRequest, now: now)

        try await queue.parkForAuth()

        #expect(try await queue.snapshot(id: pending.id)?.state == .authRequired)
        #expect(try await queue.snapshot(id: inFlight.id)?.state == .authRequired)
        // Settled records are untouched: a delivered capture is not un-delivered,
        // a terminal failure is not resurrected.
        #expect(try await queue.snapshot(id: succeeded.id)?.state == .succeeded)
        #expect(try await queue.snapshot(id: failed.id)?.state == .failed)
    }

    @Test func parkedRecordsAreNeverClaimedUntilResumed() async throws {
        let fixture = try Fixture()
        let queue = fixture.makeQueue()
        let now = Date(timeIntervalSince1970: 1_000_000)

        let snapshot = try await queue.enqueue(note: note(), now: now)
        try await queue.parkForAuth()

        // Parked: a drain finds nothing however far the clock advances.
        #expect(try await queue.claimDue(now: now.addingTimeInterval(10_000)).isEmpty)

        try await queue.resumeAfterAuth(now: now)
        let revived = try #require(try await queue.snapshot(id: snapshot.id))
        #expect(revived.state == .pending)
        #expect(revived.nextAttemptAt == now)
        #expect(revived.lastErrorCode == nil)

        let claimed = try await queue.claimDue(now: now)
        #expect(claimed.map(\.id) == [snapshot.id])
    }

    // MARK: - Drain serialization

    @Test func beginDrainIsExclusiveUntilEnded() async throws {
        let fixture = try Fixture()
        let queue = fixture.makeQueue()

        // First claim takes the slot; a second is refused while it is held.
        #expect(await queue.beginDrain() == true)
        #expect(await queue.beginDrain() == false)

        // Releasing lets the next pass claim it.
        await queue.endDrain()
        #expect(await queue.beginDrain() == true)
    }

    // MARK: - Pruning (SPEC 8.1)

    @Test func pruneRemovesSucceededRecordsPastRetentionAndKeepsTheRest() async throws {
        let fixture = try Fixture()
        let queue = fixture.makeQueue()
        let now = Date(timeIntervalSince1970: 2_000_000)
        let old = now.addingTimeInterval(-8 * 24 * 60 * 60)   // 8 days ago
        let recent = now.addingTimeInterval(-1 * 24 * 60 * 60) // yesterday

        let stale = try await queue.enqueue(note: note("stale"), now: old)
        try await queue.markSucceeded(id: stale.id, experienceID: "old")
        let fresh = try await queue.enqueue(note: note("fresh"), now: recent)
        try await queue.markSucceeded(id: fresh.id, experienceID: "new")
        let pending = try await queue.enqueue(note: note("pending"), now: old) // old but not succeeded

        try await queue.prune(now: now)

        #expect(try await queue.snapshot(id: stale.id) == nil)
        #expect(try await queue.snapshot(id: fresh.id)?.state == .succeeded)
        #expect(try await queue.snapshot(id: pending.id)?.state == .pending)
    }

    @Test func pruneReclaimsStaleFailedPhotosAndTheirSpoolFilesToBoundDiskGrowth() async throws {
        let fixture = try Fixture()
        let queue = fixture.makeQueue()
        let now = Date(timeIntervalSince1970: 2_000_000)
        let old = now.addingTimeInterval(-8 * 24 * 60 * 60)
        let recent = now.addingTimeInterval(-1 * 24 * 60 * 60)

        // A terminally failed photo still holds its derivative; nothing but prune
        // reclaims it, so without this a server-rejected photo leaks disk forever.
        let staleURL = fixture.appGroup.photoSpoolFileURL(named: "stale.jpg")
        let recentURL = fixture.appGroup.photoSpoolFileURL(named: "recent.jpg")
        try Data("stale-bytes".utf8).write(to: staleURL)
        try Data("recent-bytes".utf8).write(to: recentURL)

        let stale = try await queue.enqueue(photo: photo(filename: "stale.jpg"), now: old)
        try await queue.markFailed(id: stale.id, error: .badRequest, now: old)
        let recentFailed = try await queue.enqueue(photo: photo(filename: "recent.jpg"), now: recent)
        try await queue.markFailed(id: recentFailed.id, error: .badRequest, now: recent)

        try await queue.prune(now: now)

        #expect(try await queue.snapshot(id: stale.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: staleURL.path))
        // The recent failure stays visible and its bytes exportable until it ages out.
        #expect(try await queue.snapshot(id: recentFailed.id)?.state == .failed)
        #expect(FileManager.default.fileExists(atPath: recentURL.path))
    }
}
