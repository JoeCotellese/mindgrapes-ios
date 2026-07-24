// ABOUTME: A rough sign-in screen to exercise discovery (#9) and the OAuth flow (#10) by hand.
// ABOUTME: ponytail: throwaway. The real connect/onboarding screen (#16) replaces this wholesale.

import MindGrapesKit
import OSLog
import SwiftUI

private let log = Logger(subsystem: "net.cotellese.mindgrapes", category: "signin")

/// One field, a Check button, a Sign in button, and a status line. Enough to run
/// the whole Slice 1 sign-in path against a real server; deliberately dumb.
struct SignInView: View {
    // ponytail: default to the dev brain so a HITL run is one tap. Editable.
    @State private var urlText = "https://openbrain-mcp.perch-iwato.ts.net"
    @State private var status = "Enter your Mind Grapes server URL."
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("MindGrapes")
                .font(.largeTitle.bold())

            TextField("brain.example.com", text: $urlText)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)

            HStack {
                Button("Check", action: check)
                Button("Sign in", action: signIn)
                    .buttonStyle(.borderedProminent)
            }
            .disabled(busy)

            Text(status)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding()
    }

    private func check() {
        guard let base = ServerDiscovery.normalizedURL(from: urlText) else {
            status = "That is not a URL I can use."
            return
        }
        log.debug("check: probing \(base.absoluteString, privacy: .public)")
        busy = true
        Task {
            let client = BrainClient(config: ServerConfig(baseURL: base), session: .shared)
            let result = await client.probeReachability()
            log.debug("check: result \(String(describing: result), privacy: .public)")
            status = switch result {
            case .reachable: "Reachable ✓"
            case .wrongHost: "Something answered, but it is not a Mind Grapes server."
            case .unreachable: "Could not reach a server at that URL."
            }
            busy = false
        }
    }

    private func signIn() {
        guard let base = ServerDiscovery.normalizedURL(from: urlText) else {
            status = "That is not a URL I can use."
            return
        }
        busy = true
        Task {
            do {
                log.debug("signIn: discovering metadata at \(base.absoluteString, privacy: .public)")
                status = "Discovering…"
                let metadata = try await AuthManager.discoverMetadata(baseURL: base, session: .shared)
                log.debug("signIn: metadata token=\(metadata.tokenEndpoint.absoluteString, privacy: .public)")

                // ponytail: no keychain access group. The shared group is for a
                // future extension (SPEC 5.4); naming it needs provisioning the
                // app does not have yet (-34018 on device). App-default keychain
                // is fine for Slice 1's single process. Restore the group with
                // the extension in Slice 5.
                let auth = AuthManager(session: .shared, store: TokenStore(accessGroup: nil), metadata: metadata)

                log.debug("signIn: opening consent sheet")
                status = "Opening sign-in…"
                try await InteractiveSignIn(auth: auth, web: WebAuthenticationSession()).run()

                log.debug("signIn: success")
                status = "Signed in ✓"
            } catch AuthError.signInCancelled {
                log.debug("signIn: cancelled")
                status = "Sign in cancelled."
            } catch {
                log.error("signIn: failed \(String(describing: error), privacy: .public)")
                status = "Sign in failed: \(error)"
            }
            busy = false
        }
    }
}

#Preview {
    SignInView()
}
