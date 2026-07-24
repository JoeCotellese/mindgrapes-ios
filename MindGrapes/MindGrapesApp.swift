// ABOUTME: App entry point for the MindGrapes iOS capture app.
// ABOUTME: Shows the throwaway sign-in screen (item 10) until the real capture screen lands (issue 17).

import SwiftUI

@main
struct MindGrapesApp: App {
    var body: some Scene {
        WindowGroup {
            SignInView()
        }
    }
}
