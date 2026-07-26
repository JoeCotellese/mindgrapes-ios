// ABOUTME: Entry point for the MindGrapes watch app, a companion of the phone app.
// ABOUTME: One scene, one screen; the wrist has nothing to navigate to (SPEC 10.8).

import SwiftUI

@main
struct MindGrapesWatchApp: App {
    // ponytail: prototype source. /implement swaps this for WatchCaptureRelay,
    // which owns the WCSession and stamps each capture's identity on the wrist.
    //
    // When it does, activation must not ride on this initializer: SwiftUI resolves
    // a @State initial value lazily, on first body evaluation, so activating a
    // WCSession from `init` would tie a background-delivery prerequisite to the UI
    // happening to appear. It belongs in an explicit `.task` or a
    // WKApplicationDelegate.
    @State private var handoff = PrototypeHandoff()

    var body: some Scene {
        WindowGroup {
            WristCaptureView(status: handoff.status) { handoff.submit($0) }
        }
    }
}
