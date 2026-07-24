// ABOUTME: Proves NoteDrainer.drainOnce carries a note to succeeded and records each failure class.
// ABOUTME: Serialized: every test opens a real store and scripts the process-global stub channel.

import Foundation
import SwiftData
import Testing

@testable import MindGrapesKit

/// One store and one stub channel per pass, both process-global, so this suite
/// is serialized like the other store-backed suites (see ``CaptureQueueTests``).
@Suite(.serialized)
struct NoteDrainerTests {
    private final class Fixture {
        let directory: URL
        let container: ModelContainer
        let appGroup: AppGroupContainer

        init() throws {
            directory = URL.temporaryDirectory.appending(path: "MindGrapesDrainTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            container = try ModelContainer(
                for: CaptureRecord.self,
                configurations: ModelConfiguration(url: directory.appending(path: "captures.store"))
            )
            appGroup = AppGroupContainer(rootURL: directory)
            try appGroup.prepareDirectories()
        }

        func makeQueue() -> CaptureQueue {
            CaptureQueue(container: container, appGroup: appGroup, rng: SeededRandomNumberGenerator(seed: 1))
        }

        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    private func client() -> BrainClient {
        BrainClient(
            config: ServerConfig(baseURL: URL(string: "https://grapes.example.ts.net")!),
            session: NoteDrainerStubURLProtocol.makeSession()
        )
    }

    private func drainer(
        queue: CaptureQueue,
        token: @escaping @Sendable () async throws -> String = { "test-token" }
    ) -> NoteDrainer {
        NoteDrainer(queue: queue, client: client(), accessToken: token)
    }

    private func note(_ content: String = "A note.") throws -> NoteDraft {
        try #require(NoteDraft(content: content))
    }

    // MARK: - Success

    @Test func aDueNoteReachesSucceededWithItsExperienceID() async throws {
        NoteDrainerStubURLProtocol.install(status: 200, text: #"{"experience_id":"exp-1"}"#)
        defer { NoteDrainerStubURLProtocol.reset() }

        let fixture = try Fixture()
        let queue = fixture.makeQueue()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let enqueued = try await queue.enqueue(note: note(), now: now)

        let result = try await drainer(queue: queue).drainOnce(now: now)

        #expect(result.map(\.id) == [enqueued.id])
        #expect(result.first?.state == .succeeded)
        #expect(result.first?.experienceID == "exp-1")
    }

    @Test func anEmptyOutboxIsANoOp() async throws {
        // No stub installed on purpose: a no-op pass must not send anything.
        let fixture = try Fixture()
        let queue = fixture.makeQueue()

        let result = try await drainer(queue: queue).drainOnce(now: Date(timeIntervalSince1970: 1_000_000))

        #expect(result.isEmpty)
    }

    // MARK: - Failure classes

    @Test func aRetryableFailureLeavesTheNotePendingAndBackedOff() async throws {
        NoteDrainerStubURLProtocol.install(status: 502)
        defer { NoteDrainerStubURLProtocol.reset() }

        let fixture = try Fixture()
        let queue = fixture.makeQueue()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let enqueued = try await queue.enqueue(note: note(), now: now)

        let result = try await drainer(queue: queue).drainOnce(now: now)

        let snapshot = try #require(result.first)
        #expect(snapshot.id == enqueued.id)
        #expect(snapshot.state == .pending)
        #expect(snapshot.attemptCount == 1)
        #expect(snapshot.nextAttemptAt > now)
        #expect(snapshot.lastErrorCode == "502")
    }

    @Test func aTerminalFailureFailsTheNoteAndKeepsItVisible() async throws {
        NoteDrainerStubURLProtocol.install(status: 400)
        defer { NoteDrainerStubURLProtocol.reset() }

        let fixture = try Fixture()
        let queue = fixture.makeQueue()
        let now = Date(timeIntervalSince1970: 1_000_000)
        try await queue.enqueue(note: note(), now: now)

        let result = try await drainer(queue: queue).drainOnce(now: now)

        #expect(result.first?.state == .failed)
        #expect(result.first?.lastErrorCode == "400")
    }

    // MARK: - Auth

    @Test func aDeadRefreshParksTheWholeQueue() async throws {
        // No stub: the token provider fails before any request is made.
        let fixture = try Fixture()
        let queue = fixture.makeQueue()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let first = try await queue.enqueue(note: note("one"), now: now)
        let second = try await queue.enqueue(note: note("two"), now: now)

        let result = try await drainer(queue: queue, token: { throw AuthError.authRequired })
            .drainOnce(now: now)

        #expect(Set(result.map(\.state)) == [.authRequired])
        #expect(try await queue.snapshot(id: first.id)?.state == .authRequired)
        #expect(try await queue.snapshot(id: second.id)?.state == .authRequired)
    }

    @Test func aTransportErrorGettingTheTokenAbortsAndLeavesTheNoteReclaimable() async throws {
        // A network blip during refresh must not park (that would force a needless
        // re-sign-in). The record is left inFlight; the next pass reclaims it.
        NoteDrainerStubURLProtocol.install(status: 200, text: #"{"experience_id":"exp-9"}"#)
        defer { NoteDrainerStubURLProtocol.reset() }

        let fixture = try Fixture()
        let queue = fixture.makeQueue()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let enqueued = try await queue.enqueue(note: note(), now: now)

        // First pass: token fetch throws a transport error, aborting mid-pass.
        await #expect(throws: AuthError.self) {
            _ = try await drainer(queue: queue, token: { throw AuthError.transport(.timedOut) })
                .drainOnce(now: now)
        }
        #expect(try await queue.snapshot(id: enqueued.id)?.state == .inFlight)

        // Second pass with a working token: recoverInterrupted reclaims it, it sends.
        let result = try await drainer(queue: queue).drainOnce(now: now)
        #expect(result.first?.state == .succeeded)
        #expect(result.first?.experienceID == "exp-9")
    }
}
