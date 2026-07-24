// ABOUTME: Proves CaptureDrainer.drainOnce carries notes and photos to succeeded and records each failure class.
// ABOUTME: Serialized: every test opens a real store and scripts the process-global stub channel.

import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import Testing
import UniformTypeIdentifiers

@testable import MindGrapesKit

/// One store and one stub channel per pass, both process-global, so this suite
/// is serialized like the other store-backed suites (see ``CaptureQueueTests``).
@Suite(.serialized)
struct CaptureDrainerTests {
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
            session: CaptureDrainerStubURLProtocol.makeSession()
        )
    }

    private func drainer(
        queue: CaptureQueue,
        token: @escaping @Sendable () async throws -> String = { "test-token" }
    ) -> CaptureDrainer {
        CaptureDrainer(queue: queue, client: client(), accessToken: token)
    }

    private func note(_ content: String = "A note.") throws -> NoteDraft {
        try #require(NoteDraft(content: content))
    }

    /// Spools a real derivative into the fixture's App Group and returns a draft
    /// naming it, so the drain reads bytes the same way production does.
    private func photo(into appGroup: AppGroupContainer, description: String = "A photo.") throws -> PhotoDraft {
        let filename = try PhotoSpooler.spool(jpegFixture(), into: appGroup)
        return try #require(PhotoDraft(imageFilename: filename, description: description))
    }

    // MARK: - Success

    @Test func aDueNoteReachesSucceededWithItsExperienceID() async throws {
        CaptureDrainerStubURLProtocol.install(status: 200, text: #"{"experience_id":"exp-1"}"#)
        defer { CaptureDrainerStubURLProtocol.reset() }

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
        CaptureDrainerStubURLProtocol.install(status: 502)
        defer { CaptureDrainerStubURLProtocol.reset() }

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
        CaptureDrainerStubURLProtocol.install(status: 400)
        defer { CaptureDrainerStubURLProtocol.reset() }

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
        CaptureDrainerStubURLProtocol.install(status: 200, text: #"{"experience_id":"exp-9"}"#)
        defer { CaptureDrainerStubURLProtocol.reset() }

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

    // MARK: - Photos

    @Test func aDuePhotoReachesSucceededWithItsExperienceID() async throws {
        CaptureDrainerStubURLProtocol.install(status: 200, text: #"""
        {"experience_id":"exp-p","attachment_id":"att-1","object_key":"k","byte_len":1234}
        """#)
        defer { CaptureDrainerStubURLProtocol.reset() }

        let fixture = try Fixture()
        let queue = fixture.makeQueue()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let enqueued = try await queue.enqueue(photo: photo(into: fixture.appGroup), now: now)

        let result = try await drainer(queue: queue).drainOnce(now: now)

        #expect(result.map(\.id) == [enqueued.id])
        #expect(result.first?.state == .succeeded)
        #expect(result.first?.experienceID == "exp-p")
        // Success deletes the spool file (SPEC 8.1).
        let snapshot = try await queue.snapshot(id: enqueued.id)
        #expect(snapshot?.state == .succeeded)
    }

    @Test func aPhotoAndANoteBothDrainInOnePass() async throws {
        // The stub answers both endpoints; each door's response decodes independently.
        CaptureDrainerStubURLProtocol.install { request in
            let path = request.url?.path ?? ""
            let text = path.hasSuffix("/capture/image")
                ? #"{"experience_id":"exp-img","attachment_id":"a","object_key":"k","byte_len":9}"#
                : #"{"experience_id":"exp-note"}"#
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return .success((response, Data(text.utf8)))
        }
        defer { CaptureDrainerStubURLProtocol.reset() }

        let fixture = try Fixture()
        let queue = fixture.makeQueue()
        let now = Date(timeIntervalSince1970: 1_000_000)
        try await queue.enqueue(note: note("first"), now: now)
        try await queue.enqueue(photo: photo(into: fixture.appGroup), now: now.addingTimeInterval(1))

        let result = try await drainer(queue: queue).drainOnce(now: now.addingTimeInterval(2))

        #expect(result.count == 2)
        #expect(Set(result.map(\.state)) == [.succeeded])
        #expect(Set(result.compactMap(\.experienceID)) == ["exp-note", "exp-img"])
    }

    @Test func aPhotoWhoseSpoolFileVanishedFailsTerminallyWithoutAbortingThePass() async throws {
        // The note must still send even though the photo cannot encode.
        CaptureDrainerStubURLProtocol.install(status: 200, text: #"{"experience_id":"exp-note"}"#)
        defer { CaptureDrainerStubURLProtocol.reset() }

        let fixture = try Fixture()
        let queue = fixture.makeQueue()
        let now = Date(timeIntervalSince1970: 1_000_000)

        let photoDraft = try photo(into: fixture.appGroup)
        let photoRecord = try await queue.enqueue(photo: photoDraft, now: now)
        let noteRecord = try await queue.enqueue(note: note("survivor"), now: now.addingTimeInterval(1))
        // Delete the spool file out from under the photo, simulating a lost derivative.
        try FileManager.default.removeItem(at: fixture.appGroup.photoSpoolFileURL(named: photoDraft.imageFilename))

        _ = try await drainer(queue: queue).drainOnce(now: now.addingTimeInterval(2))

        let photoSnapshot = try await queue.snapshot(id: photoRecord.id)
        #expect(photoSnapshot?.state == .failed)
        #expect(photoSnapshot?.lastErrorCode == "spool_missing")
        // The note behind it in the queue was not stranded by the photo's failure.
        let noteSnapshot = try await queue.snapshot(id: noteRecord.id)
        #expect(noteSnapshot?.state == .succeeded)
    }

    @Test func aRetryablePhotoFailureLeavesItPendingAndBackedOff() async throws {
        CaptureDrainerStubURLProtocol.install(status: 502)
        defer { CaptureDrainerStubURLProtocol.reset() }

        let fixture = try Fixture()
        let queue = fixture.makeQueue()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let enqueued = try await queue.enqueue(photo: photo(into: fixture.appGroup), now: now)

        let result = try await drainer(queue: queue).drainOnce(now: now)

        let snapshot = try #require(result.first)
        #expect(snapshot.id == enqueued.id)
        #expect(snapshot.state == .pending)
        #expect(snapshot.attemptCount == 1)
        #expect(snapshot.lastErrorCode == "502")
    }

    // MARK: - Fixture

    /// A tiny valid JPEG, drawn in code so the repo carries no binary assets.
    private func jpegFixture() -> Data {
        let width = 120, height = 80
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = 40; pixels[i + 1] = 160; pixels[i + 2] = 90; pixels[i + 3] = 255
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
        let buffer = NSMutableData()
        let dest = CGImageDestinationCreateWithData(buffer, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        _ = CGImageDestinationFinalize(dest)
        return buffer as Data
    }
}
