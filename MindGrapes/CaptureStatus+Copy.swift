// ABOUTME: The user-facing line, symbol, and tint for each CaptureStatus on the capture screen.
// ABOUTME: Copy lives here rather than in the kit, matching WristStatus+Copy on the watch.

import MindGrapesKit
import SwiftUI

extension CaptureStatus {
    /// The status line. One sentence, in the user's terms, never an error code.
    var message: String {
        switch self {
        case .ready: ""
        case .working: "Saving…"
        case .saved: "Saved"
        case .queued: "Saved. It'll sync when you're online."
        case .pending(let count) where count > 1: "Saved. \(count) captures still syncing."
        case .pending: "Saved. Still syncing."
        case .synced: "All captures synced"
        case .needsSignIn: "Saved. Sign in again to send it."
        case .sendFailed: "Saved here, but the server refused it."
        case .nothingToSave: "Nothing to save yet."
        case .unreadableImage: "That photo couldn't be read."
        case .captureLost: "That capture couldn't be saved. Try again."
        case .storageUnavailable: "Couldn't open local storage. Try reopening the app."
        case .notSignedIn: "Sign in to start capturing."
        case .locationOff: "Location is off. Turn it on in Settings to tag captures."
        }
    }

    /// The leading symbol, or `nil` for states that carry no icon. `working` has
    /// none because the screen shows a spinner in its place.
    var symbolName: String? {
        switch self {
        case .ready, .working: nil
        case .saved, .synced: "checkmark.circle.fill"
        case .queued, .pending: "arrow.triangle.2.circlepath"
        case .needsSignIn, .notSignedIn: "person.crop.circle.badge.exclamationmark"
        case .locationOff: "location.slash"
        case .sendFailed, .nothingToSave, .unreadableImage, .captureLost, .storageUnavailable:
            "exclamationmark.circle.fill"
        }
    }

    /// Green for landed, orange for in-flight, red for anything needing the user.
    var tint: Color {
        if isFailure { return .red }
        switch self {
        case .saved, .synced: return .green
        case .queued, .pending: return .orange
        default: return .secondary
        }
    }
}
