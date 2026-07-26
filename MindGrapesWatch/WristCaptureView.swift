// ABOUTME: The whole watch app: one capture button and one honest status line.
// ABOUTME: Takes its status and its submit action from outside so it renders without a WCSession.

import MindGrapesKit
import SwiftUI

/// The wrist's only screen (SPEC 10.8).
///
/// One `TextFieldLink`, because the system input sheet it presents already offers
/// dictation, Scribble, and the keyboard. That is the noisy-place fallback,
/// already built, already localized, already accessible — a hand-authored
/// canned-phrase list would be a worse version of it that we would then have to
/// maintain.
///
/// The view owns no state and no session. Status comes in, submitted text goes
/// out; that is what lets it render under a preview and a screenshot harness with
/// no counterpart app anywhere.
struct WristCaptureView: View {
    let status: WristStatus

    /// Called with whatever the input sheet returned, unfiltered.
    ///
    /// Validation belongs to the session owner, not here: it is the only thing
    /// that can turn a blank dictation into ``WristStatus/nothingHeard`` on the
    /// wrist, and the wrist is where that has to happen (see that case's note).
    /// `@MainActor` is declared rather than inferred so a future off-main caller
    /// is a compile error instead of a latent race; `TextFieldLink`'s `onSubmit`
    /// is `nonisolated` in the SDK.
    let submit: @MainActor (String) -> Void

    /// Called when the button is pressed, before the user has said anything, so the
    /// session owner can start a location request that is ready by the time the
    /// dictation comes back. See `WatchCaptureRelay.beginCapture()` for why the fix
    /// cannot wait until submit.
    var beginCapture: @MainActor () -> Void = {}

    var body: some View {
        NavigationStack {
            VStack(spacing: 6) {
                TextFieldLink(prompt: Text("What happened?")) {
                    Label("Capture", systemImage: "mic.fill")
                        .frame(maxWidth: .infinity)
                } onSubmit: { text in
                    submit(text)
                }
                // TextFieldLink offers no will-present hook, and a plain tap gesture
                // would swallow the press the button needs. Simultaneous is what
                // lets both happen.
                .simultaneousGesture(TapGesture().onEnded { beginCapture() })
                // Tint comes from the target's AccentColor asset, which carries the
                // app icon's own colour. Without it a prominent button resolves to
                // a flat grey that reads as disabled.
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityLabel("Capture a thought")
                .accessibilityHint("Opens dictation, Scribble, or the keyboard")

                statusLine
            }
            .padding(.horizontal, 2)
            .navigationTitle("MindGrapes")
        }
    }

    /// The status line is the entire honesty mechanism of this screen, so the text
    /// is not `.secondary`; only the glyph is.
    private var statusLine: some View {
        Label {
            Text(status.message)
                .font(.footnote)
                .multilineTextAlignment(.center)
        } icon: {
            Image(systemName: status.symbolName)
                .foregroundStyle(.secondary)
        }
        // The line changes while the user is not touching anything (a transfer
        // completes with the screen up), and SwiftUI has no live-region API:
        // `.updatesFrequently` is the trait for stopwatches and tells VoiceOver
        // the element is not worth announcing, which is the opposite of what this
        // needs. An explicit announcement is the only thing that speaks.
        .onChange(of: status) { _, new in
            AccessibilityNotification.Announcement(new.message).post()
        }
    }
}

#Preview("Activating") {
    WristCaptureView(status: .activating, submit: { _ in })
}

#Preview("Ready") {
    WristCaptureView(status: .ready, submit: { _ in })
}

#Preview("Waiting") {
    WristCaptureView(status: .waiting(count: 1, phoneNearby: true), submit: { _ in })
}

#Preview("Waiting, several") {
    WristCaptureView(status: .waiting(count: 3, phoneNearby: true), submit: { _ in })
}

#Preview("Phone not nearby") {
    WristCaptureView(status: .waiting(count: 1, phoneNearby: false), submit: { _ in })
}

#Preview("No app on the phone") {
    WristCaptureView(status: .companionAppMissing, submit: { _ in })
}

#Preview("With the phone") {
    WristCaptureView(status: .withPhone, submit: { _ in })
}

#Preview("Failed") {
    WristCaptureView(status: .failed(count: 1), submit: { _ in })
}

#Preview("Nothing heard") {
    WristCaptureView(status: .nothingHeard, submit: { _ in })
}
