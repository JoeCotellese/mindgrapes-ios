// ABOUTME: The watchOS consent sheet behind the Kit's OAuthWebAuthenticating seam.
// ABOUTME: Same shape as the iOS one minus the presentation anchor, which watchOS does not take.

import AuthenticationServices
import Foundation
import MindGrapesKit

/// Presents the OAuth consent page on watchOS.
///
/// The difference from the iOS implementation is what is missing:
/// `presentationContextProvider` is `API_UNAVAILABLE(watchos)`, so the system
/// owns the presentation and there is no anchor to supply. Everything else,
/// including the callback-scheme matching, is the same call.
@MainActor
final class WatchWebAuthenticationSession: NSObject, OAuthWebAuthenticating {
    // ponytail: retain the in-flight session so ARC does not deallocate it
    // before the callback, same as the iOS implementation.
    private var session: ASWebAuthenticationSession?

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callback: .customScheme(callbackScheme)
            ) { callbackURL, error in
                if let error {
                    let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                    continuation.resume(throwing: cancelled ? AuthError.signInCancelled : error)
                } else if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: AuthError.malformedResponse)
                }
            }
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            guard session.start() else {
                // On watchOS this is the interesting failure: it means the system
                // declined to present the sheet at all, which is a different
                // answer than "the sheet opened but the passkey step failed".
                continuation.resume(throwing: AuthError.signInCancelled)
                return
            }
        }
    }
}
