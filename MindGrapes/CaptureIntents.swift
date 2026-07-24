// ABOUTME: The App Intents (Siri + Shortcuts) for capturing a note or photo and opening the capture screen.
// ABOUTME: Thin wrappers over CaptureIntentRunner; the tested pipeline logic lives in the kit.

import AppIntents
import Foundation
import MindGrapesKit

/// "Hey Siri, capture a thought." Prompts for the note, runs the pipeline, and
/// speaks the outcome. The result never waits on the round-trip (SPEC 7.1).
struct CaptureNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture a Note"
    static let description = IntentDescription("Save a quick thought to MindGrapes.")

    @Parameter(title: "Note", requestValueDialog: "What's on your mind?")
    var text: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let runner = try? AppComposition.make().runner else {
            return .result(dialog: notOnboardedDialog)
        }
        let outcome = await runner.captureNote(text)
        return .result(dialog: IntentDialog(stringLiteral: outcome.spokenPhrase))
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
        guard let runner = try? AppComposition.make().runner else {
            return .result(dialog: notOnboardedDialog)
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

extension CaptureOutcome {
    /// What Siri says back. Success either way (SPEC 7.1): a queued capture is
    /// safe on disk and will sync.
    var spokenPhrase: String {
        switch self {
        case .confirmed: "Saved."
        case .queued: "Saved. It'll sync when you're back online."
        case .rejected: "There was nothing to save."
        }
    }
}

/// The zero-config Siri phrases. Every entry point runs the same intent, so the
/// pipeline is exercised identically from voice, the Shortcuts app, and the UI.
struct MindGrapesShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CaptureNoteIntent(),
            phrases: [
                "Capture a thought in \(.applicationName)",
                "Capture a note in \(.applicationName)",
                "New note in \(.applicationName)",
            ],
            shortTitle: "Capture Note",
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
