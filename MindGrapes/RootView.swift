// ABOUTME: The app root: shows capture when signed in, the sign-in screen otherwise.
// ABOUTME: The gate is local (stored Keychain credentials), so relaunch and offline start stay signed in.

import MindGrapesKit
import SwiftUI

/// Decides the top-level screen from whether the device holds usable credentials.
///
/// The decision is deliberately local — no metadata discovery, no token refresh —
/// so a relaunch or an offline start lands on capture without a network round
/// trip. A dead refresh token surfaces later, when the queue tries to drain and
/// parks for re-auth (SPEC 8.5); it is not this gate's job to detect.
struct RootView: View {
    @State private var signedIn = RootView.hasStoredSession()

    var body: some View {
        if signedIn {
            NavigationStack {
                CaptureView(onSignOut: { signedIn = false })
            }
        } else {
            NavigationStack {
                SignInView(onSignedIn: { signedIn = true })
            }
        }
    }

    /// Whether the Keychain holds a usable access token. A Keychain failure reads
    /// as not-signed-in, so an error sends the user to sign-in rather than
    /// trapping the launch. `accessGroup: nil` matches the rest of the app (the
    /// -34018 workaround; the shared group returns with the extension).
    static func hasStoredSession() -> Bool {
        (try? TokenStore(accessGroup: nil).hasUsableAccessToken()) ?? false
    }
}
