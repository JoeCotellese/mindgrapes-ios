// ABOUTME: The whole watch app: one capture button and one honest status line.
// ABOUTME: Takes its status and its capture action from outside so it renders without a WCSession.

import SwiftUI

/// The wrist's only screen (SPEC 10.8).
///
/// One `TextFieldLink`, because the system input sheet it presents already offers
/// dictation, Scribble, and the keyboard. That is the noisy-place fallback,
/// already built, already localized, already accessible — a hand-authored
/// canned-phrase list would be a worse version of it that we would then have to
/// maintain.
///
/// The view owns no state and no session. Status comes in, captured text goes
/// out; that is what lets it render under a preview and a screenshot harness with
/// no counterpart app anywhere.
struct CaptureView: View {
    let status: HandoffStatus
    let capture: (String) -> Void

    var body: some View {
        VStack(spacing: 6) {
            TextFieldLink(prompt: Text("What happened?")) {
                Label("Capture", systemImage: "mic.fill")
                    .frame(maxWidth: .infinity)
            } onSubmit: { text in
                capture(text)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            // The watch target carries no asset catalog, so a prominent button
            // resolves to a flat grey that reads as disabled. The tint is the app
            // icon's own colour (MindGrapes.icon/icon.json), not a new brand
            // decision.
            .tint(.brand)
            .accessibilityLabel("Capture a thought")
            .accessibilityHint("Opens dictation")

            statusLine
        }
        .padding(.horizontal, 2)
        .containerBackground(.clear, for: .navigation)
        .navigationTitle("MindGrapes")
    }

    /// Empty for ``HandoffStatus/ready``: an empty state that says nothing is
    /// better than one that says something untrue.
    @ViewBuilder private var statusLine: some View {
        if case .ready = status {
            EmptyView()
        } else {
            Label(status.message, systemImage: status.symbolName)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .multilineTextAlignment(.center)
                // The line changes without the user touching anything (a transfer
                // completes while the screen is up), so VoiceOver has to be told
                // it updates or the change is silent.
                .accessibilityAddTraits(.updatesFrequently)
        }
    }
}

extension Color {
    /// The app icon's fill colour, kept in sync with
    /// `MindGrapes.icon/icon.json`'s `automatic-gradient` by hand. The icon
    /// declares extended sRGB; every component here is inside 0...1, where
    /// extended sRGB and sRGB are the same numbers.
    static let brand = Color(.sRGB, red: 0.38039, green: 0.33333, blue: 0.96078)
}

#Preview("Ready") {
    CaptureView(status: .ready, capture: { _ in })
}

#Preview("Waiting") {
    CaptureView(status: .waiting(count: 1), capture: { _ in })
}

#Preview("Waiting, several") {
    CaptureView(status: .waiting(count: 3), capture: { _ in })
}

#Preview("With the phone") {
    CaptureView(status: .withPhone, capture: { _ in })
}
