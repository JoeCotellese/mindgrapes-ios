// ABOUTME: Proves the journaling auto-commit enqueues only new, usable moments and counts them right.
// ABOUTME: Runs over a real CaptureQueue, because "how many were added" is a claim about the store.

import Foundation
import SwiftData
import Testing

@testable import MindGrapesKit

/// Serialized for the same store-setup reason as ``WatchCaptureReceiverTests``.
@Suite(.serialized)
struct JournalingCommitTests {
    private let visitDate = Date(timeIntervalSince1970: 1_700_000_000)

    private final class Fixture {
        let directory: URL
        let queue: CaptureQueue
        private let container: ModelContainer

        init() throws {
            directory = URL.temporaryDirectory.appending(path: "JournalingCommitTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            container = try ModelContainer(
                for: CaptureRecord.self,
                configurations: ModelConfiguration(url: directory.appending(path: "captures.store"))
            )
            let appGroup = AppGroupContainer(rootURL: directory)
            try appGroup.prepareDirectories()
            queue = CaptureQueue(container: container, appGroup: appGroup)
        }

        func recordCount() throws -> Int {
            try ModelContext(container).fetch(FetchDescriptor<CaptureRecord>()).count
        }

        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    @Test("The count is the number of new memories: skips and duplicates don't count")
    func countsOnlyNewInserts() async throws {
        let fixture = try Fixture()
        let accademia = JournalingMoment(
            content: .location(place: "Galleria dell'Accademia", city: "Firenze"),
            date: visitDate, coordinate: nil
        )
        let moments = [
            accademia,
            accademia, // a duplicate in the same pull
            JournalingMoment(content: .location(place: "  ", city: "Firenze"), date: visitDate, coordinate: nil), // no text -> skipped
            JournalingMoment(content: .location(place: "Ponte Vecchio", city: "Firenze"), date: visitDate, coordinate: nil),
        ]

        let inserted = try await JournalingCommit.commit(moments, to: fixture.queue)

        #expect(inserted == 2)
        #expect(try fixture.recordCount() == 2)
    }

    @Test("Committing the same pull again adds nothing")
    func rePullAddsNothing() async throws {
        let fixture = try Fixture()
        let moments = [
            JournalingMoment(content: .location(place: "Colosseo", city: "Roma"), date: visitDate, coordinate: nil),
            JournalingMoment(content: .location(place: "Foro Romano", city: "Roma"), date: visitDate, coordinate: nil),
        ]

        let first = try await JournalingCommit.commit(moments, to: fixture.queue)
        let second = try await JournalingCommit.commit(moments, to: fixture.queue)

        #expect(first == 2)
        #expect(second == 0)
        #expect(try fixture.recordCount() == 2)
    }

    @Test("An empty selection adds nothing and does not error")
    func emptySelection() async throws {
        let fixture = try Fixture()

        let inserted = try await JournalingCommit.commit([], to: fixture.queue)

        #expect(inserted == 0)
        #expect(try fixture.recordCount() == 0)
    }
}
