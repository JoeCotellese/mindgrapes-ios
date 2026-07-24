// ABOUTME: Drives the interactive sign-in coordinator and its OAuth callback parsing (item #10).
// ABOUTME: The real ASWebAuthenticationSession is faked behind OAuthWebAuthenticating; no UI here.

import Foundation
import Testing

@testable import MindGrapesKit

// MARK: - Callback parsing (pure)

@Suite("InteractiveSignIn callback parsing")
struct InteractiveSignInCallbackTests {
    private func callback(_ query: String) -> URL {
        URL(string: "net.cotellese.mindgrapes:/oauth-callback?\(query)")!
    }

    @Test func aCodeAndStateAreReturned() throws {
        let parsed = try InteractiveSignIn.parseCallback(callback("code=abc&state=xyz"))
        #expect(parsed.code == "abc")
        #expect(parsed.state == "xyz")
    }

    @Test func anErrorParamIsAFailedAuthorization() {
        // RFC 6749 §4.1.2.1: the server reports a denial as error=.
        let error = #expect(throws: AuthError.self) {
            try InteractiveSignIn.parseCallback(callback("error=access_denied&state=xyz"))
        }
        #expect(error == .authorizationFailed("access_denied"))
    }

    @Test func aMissingCodeIsMalformed() {
        let error = #expect(throws: AuthError.self) {
            try InteractiveSignIn.parseCallback(callback("state=xyz"))
        }
        #expect(error == .malformedResponse)
    }

    @Test func aMissingStateIsMalformed() {
        let error = #expect(throws: AuthError.self) {
            try InteractiveSignIn.parseCallback(callback("code=abc"))
        }
        #expect(error == .malformedResponse)
    }
}
