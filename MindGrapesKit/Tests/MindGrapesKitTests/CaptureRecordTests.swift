// ABOUTME: Proves CaptureRecord persists and reloads intact from a real SwiftData store.
// ABOUTME: Uses a temporary directory so the suite needs no App Group container.

import Foundation
import SwiftData
import Testing

@testable import MindGrapesKit

/// A SwiftData store in a throwaway directory.
///
/// The host has no App Group container, and the acceptance criterion is a real
/// round trip, so the store is built at a temp URL rather than in memory: that
/// exercises the actual on-disk encoding of every attribute.
private struct TemporaryStore: ~Copyable {
    let directory: URL
    let container: ModelContainer

    init() throws {
        directory = URL.temporaryDirectory.appending(path: "MindGrapesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        container = try ModelContainer(
            for: CaptureRecord.self,
            configurations: ModelConfiguration(url: directory.appending(path: "captures.store"))
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func makeNoteDraft() throws -> NoteDraft {
    try #require(
        NoteDraft(
            content: "Met Lung at the LIFT Labs demo; he wants a follow-up.",
            occurredAt: Date(timeIntervalSince1970: 1_753_286_591),
            coordinate: Coordinate(latitude: 39.9526, longitude: -75.1652),
            placeLabel: "Comcast Center, Philadelphia",
            people: [Person(name: "Lung", relationship: "colleague")].compactMap { $0 },
            labels: ["lift-labs", "follow-up"]
        )
    )
}

// MARK: - Persistence

@Test func noteRecordRoundTripsThroughAStore() throws {
    let store = try TemporaryStore()
    let draft = try makeNoteDraft()
    let id = UUID()

    let writeContext = ModelContext(store.container)
    writeContext.insert(CaptureRecord(id: id, note: draft))
    try writeContext.save()

    let readContext = ModelContext(store.container)
    let records = try readContext.fetch(FetchDescriptor<CaptureRecord>())
    #expect(records.count == 1)
    let record = try #require(records.first)

    #expect(record.id == id)
    #expect(record.kind == .note)
    #expect(record.content == draft.content)
    #expect(record.occurredAt == draft.occurredAt)
    #expect(record.coordinate == draft.coordinate)
    #expect(record.placeLabel == "Comcast Center, Philadelphia")
    #expect(record.people == draft.people)
    #expect(record.labels == ["lift-labs", "follow-up"])
    #expect(record.imageFilename == nil)
    #expect(record.captureDescription == nil)
    #expect(record.ocrText == nil)
    #expect(record.event == nil)
}

@Test func photoRecordRoundTripsThroughAStore() throws {
    let store = try TemporaryStore()
    let draft = try #require(
        PhotoDraft(
            imageFilename: "A1B2.jpg",
            description: "A bag of dog food listing chicken as the first ingredient.",
            ocrText: "Ingredients: chicken, brown rice",
            event: "Grocery run",
            occurredAt: Date(timeIntervalSince1970: 1_753_286_591),
            coordinate: Coordinate(latitude: 39.9526, longitude: -75.1652),
            placeLabel: "Wegmans, Cherry Hill",
            people: [Person(name: "Anna")].compactMap { $0 },
            labels: ["groceries"]
        )
    )

    let writeContext = ModelContext(store.container)
    writeContext.insert(CaptureRecord(photo: draft))
    try writeContext.save()

    let readContext = ModelContext(store.container)
    let record = try #require(try readContext.fetch(FetchDescriptor<CaptureRecord>()).first)

    #expect(record.kind == .photo)
    #expect(record.imageFilename == "A1B2.jpg")
    #expect(record.captureDescription == draft.description)
    #expect(record.ocrText == "Ingredients: chicken, brown rice")
    #expect(record.event == "Grocery run")
    #expect(record.content == nil)
    #expect(record.people.map(\.name) == ["Anna"])
    #expect(record.labels == ["groceries"])
}

@Test func recordSurvivesClosingAndReopeningTheStore() throws {
    let directory = URL.temporaryDirectory.appending(path: "MindGrapesTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let configuration = ModelConfiguration(url: directory.appending(path: "captures.store"))
    let id = UUID()

    do {
        let container = try ModelContainer(for: CaptureRecord.self, configurations: configuration)
        let context = ModelContext(container)
        context.insert(CaptureRecord(id: id, note: try makeNoteDraft()))
        try context.save()
    }

    // A fresh container over the same file: the crash-recovery guarantee in
    // SPEC 8.1 depends on the record being durable, not merely cached.
    let reopened = try ModelContainer(for: CaptureRecord.self, configurations: configuration)
    let record = try #require(
        try ModelContext(reopened).fetch(FetchDescriptor<CaptureRecord>()).first
    )
    #expect(record.id == id)
    #expect(record.coordinate?.latitude == 39.9526)
    #expect(record.people.first?.relationship == "colleague")
}

// MARK: - Defaults and invariants

@Test func newRecordStartsPendingAndDueImmediately() throws {
    let createdAt = Date(timeIntervalSince1970: 1_753_286_591)
    let record = CaptureRecord(note: try makeNoteDraft(), createdAt: createdAt)

    #expect(record.state == .pending)
    #expect(record.attemptCount == 0)
    #expect(record.nextAttemptAt == createdAt)
    #expect(record.lastErrorCode == nil)
    #expect(record.experienceID == nil)
    #expect(record.createdAt == createdAt)
}

@Test func idIsTheIdempotencyKey() throws {
    let id = UUID()
    let record = CaptureRecord(id: id, note: try makeNoteDraft())

    // SPEC 6.5: minted once with the record and reused verbatim on every
    // retry, so it must be derived from stored state and never regenerated.
    #expect(record.idempotencyKey == id.uuidString)
    #expect(record.idempotencyKey == record.idempotencyKey)
}

@Test func coordinateIsBothOrNeither() throws {
    let record = CaptureRecord(note: try makeNoteDraft())
    #expect(record.coordinate != nil)

    record.coordinate = nil
    #expect(record.coordinate == nil)
    #expect(record.lat == nil)
    #expect(record.lng == nil)

    record.coordinate = Coordinate(latitude: -33.8688, longitude: 151.2093)
    #expect(record.lat == -33.8688)
    #expect(record.lng == 151.2093)
}

@Test func recordWithOnlyOneHalfOfAFixReportsNoLocation() throws {
    // Defensive: a store written by an older build, or a half-populated row,
    // must read as "no location" rather than as a 400 from the server.
    let record = CaptureRecord(note: try makeNoteDraft())
    record.lat = 39.9526
    record.lng = nil
    #expect(record.coordinate == nil)
}

@Test func statesAndKindsSurviveTheirRawValues() throws {
    let store = try TemporaryStore()
    let context = ModelContext(store.container)
    let record = CaptureRecord(note: try makeNoteDraft())
    record.state = .authRequired
    record.attemptCount = 3
    record.lastErrorCode = "invalid_grant"
    record.experienceID = "6C7E1E2A-0000-4000-8000-000000000001"
    context.insert(record)
    try context.save()

    let reloaded = try #require(
        try ModelContext(store.container).fetch(FetchDescriptor<CaptureRecord>()).first
    )
    #expect(reloaded.state == .authRequired)
    #expect(reloaded.attemptCount == 3)
    #expect(reloaded.lastErrorCode == "invalid_grant")
    #expect(reloaded.experienceID == "6C7E1E2A-0000-4000-8000-000000000001")
}

@Test func recordsAreFetchableByTheirStoredStateRawValue() throws {
    // Item 5 drains by state, and predicates only work against stored
    // attributes; this pins that the raw storage stays queryable.
    let store = try TemporaryStore()
    let context = ModelContext(store.container)
    let pending = CaptureRecord(note: try makeNoteDraft())
    let parked = CaptureRecord(note: try makeNoteDraft())
    parked.state = .authRequired
    context.insert(pending)
    context.insert(parked)
    try context.save()

    let pendingRaw = CaptureState.pending.rawValue
    let descriptor = FetchDescriptor<CaptureRecord>(
        predicate: #Predicate { $0.stateRaw == pendingRaw }
    )
    let found = try ModelContext(store.container).fetch(descriptor)
    #expect(found.count == 1)
    #expect(found.first?.id == pending.id)
}
