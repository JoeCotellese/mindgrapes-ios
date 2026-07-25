// ABOUTME: App entry point for the MindGrapes iOS capture app.
// ABOUTME: Shows the throwaway sign-in screen, which pushes the capture screen once signed in (issue 17 replaces both).

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
