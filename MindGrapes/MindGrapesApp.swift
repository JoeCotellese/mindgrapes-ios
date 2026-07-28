// ABOUTME: App entry point for the MindGrapes iOS capture app.
// ABOUTME: Hands straight to RootView, which gates between the connect screen and capture on stored credentials.

import SwiftUI

@main
struct MindGrapesApp: App {
    @UIApplicationDelegateAdaptor(MindGrapesAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
