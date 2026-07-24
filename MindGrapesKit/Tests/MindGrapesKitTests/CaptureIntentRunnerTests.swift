// ABOUTME: Proves the capture intent pipeline: reject empty, confirm on success, stay durable when offline or slow.
// ABOUTME: Serialized: every test opens a real store and scripts the process-global stub channel.

import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import Testing
import UniformTypeIdentifiers

@testable import MindGrapesKit

@Suite(.serialized)
struct CaptureIntentRunnerTests {
    private final class Fixture {
        let directory: URL
        let container: ModelContainer
        let appGroup: AppGroupContainer

        init() throws {
            directory = URL.temporaryDirectory.appending(path: "MindGrapesIntentTests-\(UUID().uuidString)")
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

    private func runner(
        _ fixture: Fixture,
        uploadBudget: Duration = .seconds(10),
        token: @escaping @Sendable () async throws -> String = { "test-token" }
    ) -> CaptureIntentRunner {
        let queue = fixture.makeQueue()
        let client = BrainClient(
            config: ServerConfig(baseURL: URL(string: "https://grapes.example.ts.net")!),
            session: CaptureRunnerStubURLProtocol.makeSession()
        )
        let drainer = CaptureDrainer(queue: queue, client: client, accessToken: token)
        return CaptureIntentRunner(queue: queue, drainer: drainer, appGroup: fixture.appGroup, uploadBudget: uploadBudget)
    }

    // MARK: - Notes

    @Test func anEmptyNoteIsRejectedBeforeEnqueue() async throws {
        // No stub: a rejected capture must not send anything.
        let fixture = try Fixture()
        let outcome = await runner(fixture).captureNote("   \n  ")
        #expect(outcome == .rejected(reason: "empty"))
        #expect(try await fixture.makeQueue().allSnapshots().isEmpty)
    }

    @Test func aNoteThatSendsIsConfirmedWithItsExperienceID() async throws {
        CaptureRunnerStubURLProtocol.install(status: 200, text: #"{"experience_id":"exp-note"}"#)
        defer { CaptureRunnerStubURLProtocol.reset() }

        let fixture = try Fixture()
        let outcome = await runner(fixture).captureNote("A thought.")
        #expect(outcome == .confirmed(experienceID: "exp-note"))
        #expect(try await fixture.makeQueue().allSnapshots().first?.state == .succeeded)
    }

    @Test func aNoteWithTheNetworkDownStillSucceedsAndStaysDurable() async throws {
        // SPEC 7.1: offline capture returns success and leaves a durable record.
        CaptureRunnerStubURLProtocol.installTransportFailure(.notConnectedToInternet)
        defer { CaptureRunnerStubURLProtocol.reset() }

        let fixture = try Fixture()
        let outcome = await runner(fixture).captureNote("Offline thought.")
        #expect(outcome == .queued)

        // The record exists and is still sendable (pending, backed off), not lost.
        let queue = fixture.makeQueue()
        let all = try await queue.allSnapshots()
        #expect(all.count == 1)
        #expect(all.first?.state == .pending)
    }

    @Test func aSlowUploadReturnsQueuedWithoutWaitingPastTheBudget() async throws {
        // The server never answers; a tiny budget proves the runner does not block.
        CaptureRunnerStubURLProtocol.installHang()
        defer { CaptureRunnerStubURLProtocol.reset() }

        let fixture = try Fixture()
        let outcome = await runner(fixture, uploadBudget: .milliseconds(50)).captureNote("Slow thought.")
        #expect(outcome == .queued)

        // Durable and not confirmed: the record survives the abandoned attempt.
        let queue = fixture.makeQueue()
        #expect(try await queue.allSnapshots().first?.experienceID == nil)
    }

    @Test func aTerminallyRejectedNoteReportsFailedNotQueued() async throws {
        // A 400 is terminal; the user must not be told "it'll sync".
        CaptureRunnerStubURLProtocol.install(status: 400)
        defer { CaptureRunnerStubURLProtocol.reset() }

        let fixture = try Fixture()
        let outcome = await runner(fixture).captureNote("Doomed thought.")
        #expect(outcome == .failed)
        // Still durable and visible (failed records stay for export, item 18).
        #expect(try await fixture.makeQueue().allSnapshots().first?.state == .failed)
    }

    @Test func aDeadRefreshReportsNeedsSignIn() async throws {
        // No stub: the token provider fails before any request, parking the queue.
        let fixture = try Fixture()
        let outcome = await runner(fixture, token: { throw AuthError.authRequired }).captureNote("Parked thought.")
        #expect(outcome == .needsSignIn)
        #expect(try await fixture.makeQueue().allSnapshots().first?.state == .authRequired)
    }

    // MARK: - Photos

    @Test func aPhotoThatSendsIsConfirmed() async throws {
        CaptureRunnerStubURLProtocol.install(status: 200, text: #"""
        {"experience_id":"exp-img","attachment_id":"a","object_key":"k","byte_len":9}
        """#)
        defer { CaptureRunnerStubURLProtocol.reset() }

        let fixture = try Fixture()
        let outcome = await runner(fixture).capturePhoto(jpegFixture())
        #expect(outcome == .confirmed(experienceID: "exp-img"))
        #expect(try await fixture.makeQueue().allSnapshots().first?.kind == .photo)
    }

    @Test func anUndecodablePhotoIsRejected() async throws {
        let fixture = try Fixture()
        let outcome = await runner(fixture).capturePhoto(Data([0, 1, 2, 3]))
        #expect(outcome == .rejected(reason: "bad_image"))
        #expect(try await fixture.makeQueue().allSnapshots().isEmpty)
    }

    @Test func aPhotoWithTheNetworkDownStillSucceedsAndStaysDurable() async throws {
        CaptureRunnerStubURLProtocol.installTransportFailure(.notConnectedToInternet)
        defer { CaptureRunnerStubURLProtocol.reset() }

        let fixture = try Fixture()
        let outcome = await runner(fixture).capturePhoto(jpegFixture())
        #expect(outcome == .queued)
        #expect(try await fixture.makeQueue().allSnapshots().first?.kind == .photo)
    }

    // MARK: - Fixture

    private func jpegFixture() -> Data {
        let width = 100, height = 70
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = 30; pixels[i + 1] = 140; pixels[i + 2] = 200; pixels[i + 3] = 255
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
