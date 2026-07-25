// ABOUTME: Proves the background-upload reconciler resolves each completion to the right queue outcome.
// ABOUTME: Covers SPEC 8.2: unknown tasks, duplicate/late completions, and cross-process no-ops never crash.

import Foundation
import SwiftData
import Testing

@testable import MindGrapesKit

/// One store per test, opened one at a time (the CoreData schema-setup segfault
/// under concurrent `ModelContainer` construction, same rule as
/// ``CaptureQueueTests``).
@Suite(.serialized)
struct BackgroundUploadReconcilerTests {
    private final class Fixture {
        let directory: URL
        let container: ModelContainer
        let appGroup: AppGroupContainer

        init() throws {
            directory = URL.temporaryDirectory.appending(path: "MindGrapesReconcilerTests-\(UUID().uuidString)")
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

        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    private func note(_ content: String = "A note.") throws -> NoteDraft {
        try #require(NoteDraft(content: content))
    }

    /// Enqueues a note and claims it, leaving it `inFlight` the way the uploader
    /// would just before submitting the background task.
    private func inFlightNote(_ queue: CaptureQueue, now: Date) async throws -> UUID {
        let snapshot = try await queue.enqueue(note: note(), now: now)
        _ = try await queue.claimDue(now: now)
        return snapshot.id
    }

    private func noteSuccessBody(_ experienceID: String) -> Data {
        Data(#"{"experience_id":"\#(experienceID)"}"#.utf8)
    }

    private func imageSuccessBody(_ experienceID: String) -> Data {
        Data(#"""
        {"experience_id":"\#(experienceID)","attachment_id":"att_1","object_key":"k","byte_len":1234}
        """#.utf8)
    }

    // MARK: - Success

    @Test func aSuccessfulNoteCompletionMarksTheRecordDelivered() async throws {
        let fixture = try Fixture()
        let queue = fixture.makeQueue()
        let reconciler = BackgroundUploadReconciler(queue: queue)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let id = try await inFlightNote(queue, now: now)

        let outcome = try await reconciler.reconcile(
            UploadCompletion(taskDescription: id.uuidString, statusCode: 200, responseBody: noteSuccessBody("exp_1")),
            now: now
        )

        #expect(outcome == .succeeded("exp_1"))
        let snapshot = try #require(try await queue.snapshot(id: id))
        #expect(snapshot.state == .succeeded)
        #expect(snapshot.experienceID == "exp_1")
    }

    @Test func anImageSuccessBodyDecodesThroughTheSharedEnvelope() async throws {
        let fixture = try Fixture()
        let queue = fixture.makeQueue()
        let reconciler = BackgroundUploadReconciler(queue: queue)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let id = try await inFlightNote(queue, now: now)

        let outcome = try await reconciler.reconcile(
            UploadCompletion(taskDescription: id.uuidString, statusCode: 201, responseBody: imageSuccessBody("exp_img")),
            now: now
        )

        #expect(outcome == .succeeded("exp_img"))
    }

    // MARK: - No-ops (SPEC 8.2)

    @Test func anUnknownTaskIdIsIgnored() async throws {
        let fixture = try Fixture()
        let queue = fixture.makeQueue()
        let reconciler = BackgroundUploadReconciler(queue: queue)

        let outcome = try await reconciler.reconcile(
            UploadCompletion(taskDescription: UUID().uuidString, statusCode: 200, responseBody: noteSuccessBody("x"))
        )

        #expect(outcome == .ignoredUnknownTask)
    }

    @Test func aTaskWithNoDescriptionIsIgnored() async throws {
        let fixture = try Fixture()
        let queue = fixture.makeQueue()
        let reconciler = BackgroundUploadReconciler(queue: queue)

        let outcome = try await reconciler.reconcile(
            UploadCompletion(taskDescription: nil, statusCode: 200, responseBody: noteSuccessBody("x"))
        )

        #expect(outcome == .ignoredUnknownTask)
    }

    @Test func aNonUUIDDescriptionIsIgnored() async throws {
        let fixture = try Fixture()
        let queue = fixture.makeQueue()
        let reconciler = BackgroundUploadReconciler(queue: queue)

        let outcome = try await reconciler.reconcile(
            UploadCompletion(taskDescription: "not-a-uuid", statusCode: 200, responseBody: noteSuccessBody("x"))
        )

        #expect(outcome == .ignoredUnknownTask)
    }

    @Test func aDuplicateCompletionForAnAlreadyDeliveredRecordIsANoOp() async throws {
        let fixture = try Fixture()
        let queue = fixture.makeQueue()
        let reconciler = BackgroundUploadReconciler(queue: queue)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let id = try await inFlightNote(queue, now: now)

        // First completion delivers it.
        _ = try await reconciler.reconcile(
            UploadCompletion(taskDescription: id.uuidString, statusCode: 200, responseBody: noteSuccessBody("exp_first")),
            now: now
        )
        // A second, later completion (a foreground and a background task both ran)
        // must not disturb the delivered record, even a conflicting one.
        let outcome = try await reconciler.reconcile(
            UploadCompletion(taskDescription: id.uuidString, statusCode: 200, responseBody: noteSuccessBody("exp_second")),
            now: now
        )

        #expect(outcome == .ignoredAlreadySettled)
        let snapshot = try #require(try await queue.snapshot(id: id))
        #expect(snapshot.state == .succeeded)
        #expect(snapshot.experienceID == "exp_first")
    }

    @Test func aLateSuccessDoesNotResurrectATerminallyFailedRecord() async throws {
        let fixture = try Fixture()
        let queue = fixture.makeQueue()
        let reconciler = BackgroundUploadReconciler(queue: queue)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let id = try await inFlightNote(queue, now: now)

        // A 400 fails it terminally.
        _ = try await reconciler.reconcile(
            UploadCompletion(taskDescription: id.uuidString, statusCode: 400),
            now: now
        )
        // A stray success for the same record arrives afterward.
        let outcome = try await reconciler.reconcile(
            UploadCompletion(taskDescription: id.uuidString, statusCode: 200, responseBody: noteSuccessBody("late")),
            now: now
        )

        #expect(outcome == .ignoredAlreadySettled)
        let snapshot = try #require(try await queue.snapshot(id: id))
        #expect(snapshot.state == .failed)
        #expect(snapshot.experienceID == nil)
    }

    // MARK: - Failures classified like the in-process path

    @Test func aTransportErrorRetriesWithBackoff() async throws {
        let fixture = try Fixture()
        let queue = fixture.makeQueue()
        let reconciler = BackgroundUploadReconciler(queue: queue)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let id = try await inFlightNote(queue, now: now)

        let outcome = try await reconciler.reconcile(
            UploadCompletion(taskDescription: id.uuidString, statusCode: nil, transportErrorCode: .notConnectedToInternet),
            now: now
        )

        #expect(outcome == .failed("transport(\(URLError.Code.notConnectedToInternet.rawValue))"))
        let snapshot = try #require(try await queue.snapshot(id: id))
        #expect(snapshot.state == .pending)
        #expect(snapshot.attemptCount == 1)
        #expect(snapshot.nextAttemptAt > now)
    }

    @Test func aBadRequestFailsTerminally() async throws {
        let fixture = try Fixture()
        let queue = fixture.makeQueue()
        let reconciler = BackgroundUploadReconciler(queue: queue)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let id = try await inFlightNote(queue, now: now)

        let outcome = try await reconciler.reconcile(
            UploadCompletion(taskDescription: id.uuidString, statusCode: 400),
            now: now
        )

        #expect(outcome == .failed("400"))
        let snapshot = try #require(try await queue.snapshot(id: id))
        #expect(snapshot.state == .failed)
    }

    @Test func aLoneUnauthorizedHoldsTheRecordDueNowForRefresh() async throws {
        let fixture = try Fixture()
        let queue = fixture.makeQueue()
        let reconciler = BackgroundUploadReconciler(queue: queue)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let id = try await inFlightNote(queue, now: now)

        let outcome = try await reconciler.reconcile(
            UploadCompletion(taskDescription: id.uuidString, statusCode: 401),
            now: now
        )

        #expect(outcome == .failed("401"))
        let snapshot = try #require(try await queue.snapshot(id: id))
        #expect(snapshot.state == .pending)
        #expect(snapshot.nextAttemptAt == now)
        #expect(snapshot.attemptCount == 0)
    }

    @Test func aBadGatewayRetries() async throws {
        let fixture = try Fixture()
        let queue = fixture.makeQueue()
        let reconciler = BackgroundUploadReconciler(queue: queue)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let id = try await inFlightNote(queue, now: now)

        let outcome = try await reconciler.reconcile(
            UploadCompletion(taskDescription: id.uuidString, statusCode: 502),
            now: now
        )

        #expect(outcome == .failed("502"))
        let snapshot = try #require(try await queue.snapshot(id: id))
        #expect(snapshot.state == .pending)
        #expect(snapshot.attemptCount == 1)
    }

    @Test func aSuccessStatusWithAGarbageBodyFailsAsMalformed() async throws {
        let fixture = try Fixture()
        let queue = fixture.makeQueue()
        let reconciler = BackgroundUploadReconciler(queue: queue)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let id = try await inFlightNote(queue, now: now)

        let outcome = try await reconciler.reconcile(
            UploadCompletion(taskDescription: id.uuidString, statusCode: 200, responseBody: Data("not json".utf8)),
            now: now
        )

        #expect(outcome == .failed("malformed_response"))
        let snapshot = try #require(try await queue.snapshot(id: id))
        #expect(snapshot.state == .failed)
    }

    @Test func aFinishedTaskWithNoResponseAndNoErrorIsMalformed() async throws {
        let fixture = try Fixture()
        let queue = fixture.makeQueue()
        let reconciler = BackgroundUploadReconciler(queue: queue)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let id = try await inFlightNote(queue, now: now)

        let outcome = try await reconciler.reconcile(
            UploadCompletion(taskDescription: id.uuidString, statusCode: nil),
            now: now
        )

        #expect(outcome == .failed("malformed_response"))
        let snapshot = try #require(try await queue.snapshot(id: id))
        #expect(snapshot.state == .failed)
    }
}
