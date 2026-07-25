// ABOUTME: The app root: shows capture when signed in, the connect/onboarding screen otherwise.
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
    @State private var signedIn = RootView.isOnboarded()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if signedIn {
                NavigationStack {
                    CaptureView(onSignOut: { signedIn = false })
                }
            } else {
                NavigationStack {
                    ConnectView(onSignedIn: { signedIn = true })
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Re-gate on foreground so a session that died mid-use (a dead refresh
            // deletes the tokens and parks the queue) surfaces the sign-in screen
            // on the next return, rather than stranding the user on capture with no
            // way back. A still-valid session re-reads as signed in and stays put.
            if phase == .active { signedIn = RootView.isOnboarded() }
        }
    }

    /// Whether the install is finished onboarding: usable credentials **and** an
    /// answer to the location pitch.
    ///
    /// Credentials alone would be the wrong gate. OAuth writes tokens the moment
    /// the consent sheet succeeds, so a user who backgrounds the app while the
    /// pitch is on screen would return to a capture screen having never been
    /// asked, with the location toggle sitting at its unset default of on. That
    /// is the ambush-on-first-capture #20 exists to remove.
    ///
    /// A permission iOS has already recorded counts as answered, whatever the
    /// flag says: the system prompt appears once per install, so there is
    /// nothing left to pitch. That also keeps installs that predate the flag
    /// from being sent back through onboarding.
    static func isOnboarded() -> Bool {
        guard hasStoredSession() else { return false }
        if LocationPermission.status != .notDetermined { return true }
        return SharedDefaults(appGroup: AppGroup.identifier)?.locationPitchAnswered ?? true
    }

    /// Whether the Keychain holds a usable access token. A Keychain failure reads
    /// as not-signed-in, so an error sends the user to sign-in rather than
    /// trapping the launch. `accessGroup: nil` matches the rest of the app (the
    /// -34018 workaround; the shared group returns with the extension).
    static func hasStoredSession() -> Bool {
        (try? TokenStore(accessGroup: nil).hasUsableAccessToken()) ?? false
    }
}
