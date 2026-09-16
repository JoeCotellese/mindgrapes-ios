// ABOUTME: Proves the share-extension intake maps text/URL/image shares to the right durable capture.
// ABOUTME: Runs over a real CaptureQueue, because "what landed in the outbox" is a claim about the store.

import Foundation
import SwiftData
import Testing

@testable import MindGrapesKit

/// Serialized for the same store-setup reason as the other queue-backed suites.
@Suite(.serialized)
struct ShareCaptureTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private final class Fixture {
        let directory: URL
        let appGroup: AppGroupContainer
        let queue: CaptureQueue
        private let container: ModelContainer

        init() throws {
            directory = URL.temporaryDirectory.appending(path: "ShareCaptureTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            container = try ModelContainer(
                for: CaptureRecord.self,
                configurations: ModelConfiguration(url: directory.appending(path: "captures.store"))
            )
            appGroup = AppGroupContainer(rootURL: directory)
            try appGroup.prepareDirectories()
            queue = CaptureQueue(container: container, appGroup: appGroup)
        }

        func records() throws -> [CaptureRecord] {
            try ModelContext(container).fetch(FetchDescriptor<CaptureRecord>())
        }

        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: - Content composition (pure)

    @Test("Text share becomes the text verbatim")
    func textContent() {
        let content = ShareCaptureComposer.noteContent(for: .text("A passage worth keeping"), note: nil)
        #expect(content == "A passage worth keeping")
    }

    @Test("An optional note leads the shared text, separated by a blank line")
    func textWithNote() {
        let content = ShareCaptureComposer.noteContent(for: .text("the quote"), note: "why it matters")
        #expect(content == "why it matters\n\nthe quote")
    }

    @Test("A readable URL folds title, URL, and article text like the browser extension")
    func readableURLContent() {
        let page = ReadablePage(title: "How Grapes Grow", text: "Vines need sun and time.")
        let content = ShareCaptureComposer.noteContent(
            for: .url(URL(string: "https://example.com/grapes")!, readable: page),
            note: nil
        )
        #expect(content == "How Grapes Grow\nhttps://example.com/grapes\n\nVines need sun and time.")
    }

    @Test("A URL with no readable page falls back to the bare URL")
    func bareURLContent() {
        let content = ShareCaptureComposer.noteContent(
            for: .url(URL(string: "https://example.com/x")!, readable: nil),
            note: nil
        )
        #expect(content == "https://example.com/x")
    }

    @Test("An empty readable page is treated as no page: bare URL")
    func emptyReadableIsBare() {
        let page = ReadablePage(title: "   ", text: "")
        let content = ShareCaptureComposer.noteContent(
            for: .url(URL(string: "https://example.com/x")!, readable: page),
            note: nil
        )
        #expect(content == "https://example.com/x")
    }

    @Test("An image carries no note content")
    func imageHasNoNoteContent() {
        #expect(ShareCaptureComposer.noteContent(for: .image(Data([0x1])), note: "caption") == nil)
    }

    // MARK: - JS-results mapping (the extension's decision logic)

    @Test("JS results with title and text become a readable URL item")
    func urlItemReadable() {
        let item = ShareCaptureComposer.urlItem(urlString: "https://x.com/a", title: "T", text: "Body")
        guard case .url(let url, let readable) = item else { Issue.record("expected .url"); return }
        #expect(url.absoluteString == "https://x.com/a")
        #expect(readable?.title == "T")
        #expect(readable?.text == "Body")
    }

    @Test("JS results with no readable text degrade to a bare URL")
    func urlItemBareFallback() {
        let item = ShareCaptureComposer.urlItem(urlString: "https://x.com/a", title: "  ", text: "")
        guard case .url(_, let readable) = item else { Issue.record("expected .url"); return }
        #expect(readable == nil)
    }

    @Test("A missing or malformed URL is not a capture")
    func urlItemMissingURL() {
        #expect(ShareCaptureComposer.urlItem(urlString: nil, title: "T", text: "Body") == nil)
        #expect(ShareCaptureComposer.urlItem(urlString: "   ", title: "T", text: "Body") == nil)
    }

    // MARK: - Enqueue (durable)

    @Test("Enqueuing a text share writes one note record with the composed content")
    func enqueueText() async throws {
        let fixture = try Fixture()
        let outcome = try await ShareCapture.enqueue(
            .text("Remember this"), note: nil, into: fixture.queue, appGroup: fixture.appGroup, now: now
        )

        let records = try fixture.records()
        #expect(records.count == 1)
        #expect(records.first?.kind == .note)
        #expect(records.first?.content == "Remember this")
        if case .note(let id) = outcome { #expect(id == records.first?.id) } else { Issue.record("expected .note") }
    }

    @Test("Enqueuing a readable URL writes one note record with folded content")
    func enqueueReadableURL() async throws {
        let fixture = try Fixture()
        let page = ReadablePage(title: "Title", text: "Body text.")
        _ = try await ShareCapture.enqueue(
            .url(URL(string: "https://example.com/a")!, readable: page),
            note: nil, into: fixture.queue, appGroup: fixture.appGroup, now: now
        )

        let records = try fixture.records()
        #expect(records.count == 1)
        #expect(records.first?.kind == .note)
        #expect(records.first?.content == "Title\nhttps://example.com/a\n\nBody text.")
    }

    @Test("Enqueuing an image spools the bytes and writes one photo record")
    func enqueueImage() async throws {
        let fixture = try Fixture()
        let outcome = try await ShareCapture.enqueue(
            .image(Self.onePixelPNG), note: nil, into: fixture.queue, appGroup: fixture.appGroup, now: now
        )

        let records = try fixture.records()
        #expect(records.count == 1)
        #expect(records.first?.kind == .photo)
        let filename = try #require(records.first?.imageFilename)
        #expect(FileManager.default.fileExists(atPath: fixture.appGroup.photoSpoolFileURL(named: filename).path))
        // No user note: the provisional description is the app's template fallback.
        #expect(records.first?.captureDescription == PhotoDescription.template(occurredAt: now))
        if case .photo(let id) = outcome { #expect(id == records.first?.id) } else { Issue.record("expected .photo") }
    }

    @Test("A user note on an image share becomes its description")
    func imageNoteBecomesDescription() async throws {
        let fixture = try Fixture()
        _ = try await ShareCapture.enqueue(
            .image(Self.onePixelPNG), note: "my dog at the beach",
            into: fixture.queue, appGroup: fixture.appGroup, now: now
        )
        #expect(try fixture.records().first?.captureDescription == "my dog at the beach")
    }

    @Test("Undecodable image bytes are rejected and leave no record or spool file")
    func rejectsBadImage() async throws {
        let fixture = try Fixture()
        let outcome = try await ShareCapture.enqueue(
            .image(Data([0x00, 0x01, 0x02])), note: nil,
            into: fixture.queue, appGroup: fixture.appGroup, now: now
        )
        #expect(outcome == .rejected(reason: "bad_image"))
        #expect(try fixture.records().isEmpty)
        let spool = try FileManager.default.contentsOfDirectory(atPath: fixture.appGroup.photoSpoolURL.path)
        #expect(spool.isEmpty)
    }

    /// A minimal decodable PNG (1x1) so the spool + downscale path has real bytes.
    private static let onePixelPNG: Data = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
    )!
}
