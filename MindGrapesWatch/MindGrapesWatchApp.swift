// ABOUTME: Entry point for the MindGrapes watch app, a companion of the phone app.
// ABOUTME: One scene, one screen; the wrist has nothing to navigate to (SPEC 10.8).

import SwiftUI

@main
struct MindGrapesWatchApp: App {
    // ponytail: prototype source. /implement swaps this for WatchCaptureRelay,
    // which owns the WCSession and stamps each capture's identity on the wrist.
    @State private var handoff = PrototypeHandoff()

    var body: some Scene {
        WindowGroup {
            CaptureView(status: handoff.status) { handoff.capture($0) }
        }
    }
}
