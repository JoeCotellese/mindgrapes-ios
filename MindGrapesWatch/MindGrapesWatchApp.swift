// ABOUTME: Entry point for the MindGrapes watch app, a companion of the phone app.
// ABOUTME: One scene, one screen; the wrist has nothing to navigate to (SPEC 10.8).

import SwiftUI

@main
struct MindGrapesWatchApp: App {
    @State private var relay = WatchCaptureRelay()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WristCaptureView(
                status: relay.status,
                submit: { relay.submit($0) },
                beginCapture: { relay.beginCapture() }
            )
            // Activation is explicit, not a side effect of constructing the relay.
            // SwiftUI resolves a @State initial value lazily on first body
            // evaluation, so tying session activation to the initializer would make
            // "can this wrist hand anything over" depend on when the UI appeared.
            .task { relay.activate() }
            // The one signal that fires on a resume. A watch app that is still
            // running when the wrist drops and comes back up gets no new session
            // activation and no new application context, so before this the only
            // remaining trigger was the Capture button's tap — which VoiceOver
            // never sends (#34). `.task` does not re-run here either.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { relay.beginCapture() }
            }
        }
    }
}
