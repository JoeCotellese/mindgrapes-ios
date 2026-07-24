// ABOUTME: The app's real consent sheet: an ASWebAuthenticationSession behind the Kit's OAuthWebAuthenticating seam.
// ABOUTME: Lives in the app, not MindGrapesKit, because AuthenticationServices sign-in is unavailable on watchOS.

import AuthenticationServices
import MindGrapesKit
import UIKit

/// Presents the OAuth consent page and returns the callback URL, satisfying the
/// seam ``OAuthWebAuthenticating`` that ``InteractiveSignIn`` drives. The whole
/// type is `@MainActor` because `ASWebAuthenticationSession` must start and
/// present on the main thread.
@MainActor
final class WebAuthenticationSession: NSObject, OAuthWebAuthenticating {
    // ponytail: retain the in-flight session so ARC does not deallocate it
    // before the callback. Overwritten by the next sign-in; never nil'd, which
    // is fine for a single-shot flow.
    private var session: ASWebAuthenticationSession?

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callback: .customScheme(callbackScheme)
            ) { callbackURL, error in
                if let error {
                    // A user dismissal is not a failure to shout about; map it
                    // to the quiet, retryable case the UI resets on.
                    let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                    continuation.resume(throwing: cancelled ? AuthError.signInCancelled : error)
                } else if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: AuthError.malformedResponse)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            session.start()
        }
    }
}

extension WebAuthenticationSession: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // The framework calls this on the main thread; assumeIsolated lets us
        // reach `UIApplication` without hopping.
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
            guard let scene else {
                preconditionFailure("No UIWindowScene available to anchor the sign-in sheet")
            }
            return scene.keyWindow ?? UIWindow(windowScene: scene)
        }
    }
}
