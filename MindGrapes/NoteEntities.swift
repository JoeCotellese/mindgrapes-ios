// ABOUTME: The App Intents entity types the `.notes` app schema requires of a note-taking app.
// ABOUTME: Thin value types over a capture; MindGrapes has no folders, tags, or pinning.

import AppIntents
import Foundation
import MindGrapesKit

/// The note the `.notes.createNote` schema hands back (SPEC 10.7).
///
/// MindGrapes captures are write-only until the Phase 4 read doors exist, so
/// this entity describes a capture that was just made rather than one fetched
/// from the brain. The schema's folder, tag, and pinning vocabulary has no
/// counterpart in this app and stays empty; the fields exist because the schema
/// is a contract with the system, not because the product grew filing.
@AppEntity(schema: .notes.note)
struct NoteEntity {
    static let defaultQuery = NoteEntityQuery()

    /// The capture's `idempotency_key` (SPEC 8.1), so an entity identifies the
    /// same capture the queue and the server do.
    let id: UUID

    var name: AttributedString
    var content: AttributedString?
    var attachments: [IntentFile]
    var tags: [NoteTagEntity]
    var isPinned: Bool
    var creationDate: Date?
    var modificationDate: Date?
    var folder: NoteFolderEntity?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    /// Builds the entity for a capture that was just enqueued.
    ///
    /// The schema wants a title and a capture has none, so the first line stands
    /// in — the same thing a person would read back to identify the note. The
    /// properties are assigned rather than passed to a memberwise init because
    /// the schema macro wraps most of them in an `EntityProperty`.
    init(id: UUID, text: String, createdAt: Date) {
        let firstLine = NoteTitle.firstLine(of: text)
        // The plain stored properties first: assigning through a property wrapper
        // touches `self`, which the compiler refuses until every unwrapped
        // property already holds a value. `tags` is the one the macro leaves bare.
        self.id = id
        self.tags = []
        self.name = AttributedString(firstLine)
        self.content = AttributedString(text)
        self.attachments = []
        self.isPinned = false
        self.creationDate = createdAt
        self.modificationDate = createdAt
        self.folder = nil
    }
}

/// Resolves notes by identifier for the system.
///
/// ponytail: returns nothing. Answering it needs either the payload text on
/// `CaptureSnapshot` (the queue only carries bookkeeping today) or the Phase 4
/// REST read doors, and nothing in the app can follow up on a note yet — there
/// is no browse surface to open one in. Fill this in when Phase 4 lands.
struct NoteEntityQuery: EntityQuery {
    func entities(for identifiers: [NoteEntity.ID]) async throws -> [NoteEntity] {
        []
    }
}

/// A folder, which MindGrapes does not have. The brain is one flat stream of
/// experiences; filing is what the graph is for. The type exists because
/// `.notes.createNote` requires a folder parameter, and the parameter needs
/// something to be typed as.
@AppEntity(schema: .notes.folder)
struct NoteFolderEntity {
    static let defaultQuery = NoteFolderEntityQuery()

    let id: UUID
    var name: String
    var account: NoteAccountEntity?
    var parentFolder: NoteFolderEntity?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

/// A string query because the schema requires the folder parameter to be
/// resolvable from what a person says. Nothing resolves: there are no folders.
struct NoteFolderEntityQuery: EntityStringQuery {
    func entities(for identifiers: [NoteFolderEntity.ID]) async throws -> [NoteFolderEntity] {
        []
    }

    func entities(matching string: String) async throws -> [NoteFolderEntity] {
        []
    }
}

/// The account a folder belongs to. Reachable only through `NoteFolderEntity`,
/// which is itself vestigial; a MindGrapes capture goes to the one brain the
/// device is onboarded to (SPEC 5).
@AppEntity(schema: .notes.account)
struct NoteAccountEntity {
    static let defaultQuery = NoteAccountEntityQuery()

    let id: UUID
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct NoteAccountEntityQuery: EntityQuery {
    func entities(for identifiers: [NoteAccountEntity.ID]) async throws -> [NoteAccountEntity] {
        []
    }
}

/// A tag, which MindGrapes does not have either. Captures carry `labels` on the
/// wire (SPEC 6.4), but nothing in the app sets them yet.
struct NoteTagEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Tag"
    static let defaultQuery = NoteTagEntityQuery()

    let id: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(id)")
    }
}

struct NoteTagEntityQuery: EntityQuery {
    func entities(for identifiers: [NoteTagEntity.ID]) async throws -> [NoteTagEntity] {
        []
    }
}
