// ABOUTME: The App Intents (Siri + Shortcuts) for capturing a note or photo and opening the capture screen.
// ABOUTME: Thin wrappers over CaptureIntentRunner; the tested pipeline logic lives in the kit.

import AppIntents
import Foundation
import MindGrapesKit
import OSLog
import UniformTypeIdentifiers

private let log = Logger(subsystem: "net.cotellese.mindgrapes", category: "intents")

/// "Hey Siri, capture a thought." Prompts for the note, runs the pipeline, and
/// speaks the outcome. The result never waits on the round-trip (SPEC 7.1).
///
/// The `.notes.createNote` schema is what lets Siri route a request it has never
/// seen a phrase for. Phrases alone lose: a bare "capture a thought" went to
/// Apple Notes, because without a schema the system has no idea this app takes
/// notes at all. The schema says so structurally, so Apple Intelligence can pick
/// this app for wording nobody enumerated in `MindGrapesShortcuts`.
@AppIntent(schema: .notes.createNote)
struct CaptureNoteIntent {
    static let title: LocalizedStringResource = "Capture a Note"
    static let description = IntentDescription("Save a quick thought to MindGrapes.")

    // `content` (not `text`) and `AttributedString` are the schema's vocabulary;
    // Apple Intelligence maps by property name. The schema requires it optional,
    // so the spoken prompt moves to `name`: an optional parameter is never
    // requested, and a capture with nothing in it is the one outcome to avoid.
    @Parameter(title: "Note")
    var content: AttributedString?

    // The schema's title field. Siri asks for this when a request arrives with
    // no text, which is why the dialog lives here rather than on `content`.
    @Parameter(title: "Title", requestValueDialog: "What's on your mind?")
    var name: String

    // Required by the schema, unused by this app. See NoteEntities.swift: there
    // are no folders or pinned captures in a flat stream of experiences. Photos
    // have their own intent and pipeline (SPEC 7.2), so attachments arriving here
    // are dropped rather than half-handled.
    @Parameter(title: "Attachments", default: [], supportedContentTypes: [.data])
    var attachments: [IntentFile]

    @Parameter(title: "Pinned", default: false)
    var isPinned: Bool

    @Parameter(title: "Folder")
    var folder: NoteFolderEntity?

    func perform() async throws -> some IntentResult & ReturnsValue<NoteEntity> & ProvidesDialog {
        // The server takes plain text (SPEC 6.4); the attributed run data carries
        // nothing a capture needs, so drop it at the boundary rather than teach
        // the wire encoder about styling. A request that filled in only the title
        // still captured something the user said, so it is the text.
        let text = content.map { String($0.characters) } ?? name
        let captured = NoteEntity(id: UUID(), text: text, createdAt: Date())

        let runner: CaptureIntentRunner
        do {
            runner = try AppComposition.make().runner
        } catch AppComposition.CompositionError.notOnboarded {
            return .result(value: captured, dialog: notOnboardedDialog)
        } catch {
            // A store/App-Group failure means the note was NOT saved; do not tell
            // the user to sign in (they would not retry a lost capture).
            log.error("note intent composition failed: \(String(describing: error), privacy: .public)")
            return .result(value: captured, dialog: storageFailureDialog)
        }
        let outcome = await runner.captureNote(text)
        return .result(value: captured, dialog: IntentDialog(stringLiteral: outcome.spokenPhrase))
    }
}

/// Captures a supplied image (from the Shortcuts editor or a share). Voice has no
/// image to give, so this is a Shortcuts/automation door, not a spoken one.
struct CapturePhotoIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture a Photo"
    static let description = IntentDescription("Save a photo memory to MindGrapes.")

    @Parameter(title: "Photo", supportedContentTypes: [.image])
    var photo: IntentFile

    @Parameter(title: "Description", default: "")
    var caption: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let runner: CaptureIntentRunner
        do {
            runner = try AppComposition.make().runner
        } catch AppComposition.CompositionError.notOnboarded {
            return .result(dialog: notOnboardedDialog)
        } catch {
            log.error("photo intent composition failed: \(String(describing: error), privacy: .public)")
            return .result(dialog: storageFailureDialog)
        }
        let outcome = await runner.capturePhoto(photo.data, description: caption)
        return .result(dialog: IntentDialog(stringLiteral: outcome.spokenPhrase))
    }
}

/// Opens the app so the user can capture by hand. Deep navigation to the capture
/// screen is the real onboarding/navigation work (issue 16); for now this brings
/// the app forward.
struct OpenCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Open MindGrapes"
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        .result()
    }
}

private let notOnboardedDialog = IntentDialog("Sign in to MindGrapes first, then try again.")
private let storageFailureDialog = IntentDialog("Something went wrong saving that. Please try again.")

extension CaptureOutcome {
    /// What Siri says back. A durable capture is a success (SPEC 7.1) even before
    /// it confirms; only genuine failures — a lost write, a terminal reject, or a
    /// dead session — say otherwise, so the user knows to act.
    var spokenPhrase: String {
        switch self {
        case .confirmed:
            "Saved."
        case .queued:
            "Saved. It'll sync when you're back online."
        case .needsSignIn:
            "Saved, but you'll need to sign in to MindGrapes again to send it."
        case .failed:
            "Saved, but MindGrapes couldn't send it."
        case .rejected(let reason):
            // "empty" is user-fixable input; anything else is a real save failure
            // and must not be spoken as if there was simply nothing to save.
            reason == "empty" ? "There was nothing to save." : "Something went wrong saving that. Please try again."
        }
    }
}

/// The zero-config Siri phrases. Every entry point runs the same intent, so the
/// pipeline is exercised identically from voice, the Shortcuts app, and the UI.
///
/// Every phrase must contain `.applicationName`; without it Siri never considers
/// the shortcut and a bare "capture a thought" routes to Apple Notes. The token
/// also matches the `INAlternativeAppNames` in Info.plist, so "mind grapes" and
/// "grapes" resolve too. Leading-name forms are included because Siri matches
/// them more reliably than trailing ones when the utterance is clipped.
struct MindGrapesShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CaptureNoteIntent(),
            phrases: [
                "Capture a thought in \(.applicationName)",
                "Capture a thought with \(.applicationName)",
                "\(.applicationName) capture a thought",
                "Capture a note in \(.applicationName)",
                "Capture a note with \(.applicationName)",
                "\(.applicationName) capture a note",
                "New note in \(.applicationName)",
                "Capture in \(.applicationName)",
                "\(.applicationName) capture",
            ],
            // "MindGrapes Note" rather than "Capture Note": this is the name a
            // person hunts for in the Shortcuts app, the Action Button picker,
            // and the Watch's shortcuts list, where actions from every installed
            // app sit in one flat list and "Capture Note" says nothing about
            // whose note it is.
            shortTitle: "MindGrapes Note",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: OpenCaptureIntent(),
            phrases: ["Open \(.applicationName)"],
            shortTitle: "Open MindGrapes",
            systemImageName: "plus.circle"
        )
    }
}
