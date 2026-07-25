// ABOUTME: A rough sign-in screen to exercise discovery (#9) and the OAuth flow (#10) by hand.
// ABOUTME: ponytail: throwaway. The real connect/onboarding screen (#16) replaces this wholesale.

import MindGrapesKit
import OSLog
import SwiftUI

private let log = Logger(subsystem: "net.cotellese.mindgrapes", category: "signin")

/// One field, a Check button, a Sign in button, and a status line. Enough to run
/// the whole Slice 1 sign-in path against a real server; deliberately dumb.
struct SignInView: View {
    /// Called after a successful sign-in so the root can show capture.
    let onSignedIn: () -> Void

    @State private var urlText: String
    @State private var status = "Enter your Mind Grapes server URL."
    @State private var busy = false

    init(onSignedIn: @escaping () -> Void) {
        self.onSignedIn = onSignedIn
        // Pre-fill the last connected server so re-signing in after a sign-out is
        // one tap; fall back to the dev brain on a fresh install.
        let stored = SharedDefaults(appGroup: AppGroup.identifier)?.serverConfig?.baseURL.absoluteString
        _urlText = State(initialValue: stored ?? "https://openbrain-mcp.perch-iwato.ts.net")
    }

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
            var signedInOK = false
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
                // Persist the chosen server so the capture screen (and a future
                // extension) target the same host without re-asking (SPEC 4.2).
                SharedDefaults(appGroup: AppGroup.identifier)?.serverConfig = ServerConfig(baseURL: base)
                // Revive anything a dead refresh parked (SPEC 8.5): with fresh
                // credentials the queue can drain again. The build is logged if it
                // fails so a successful-looking sign-in over a broken store leaves a
                // breadcrumb here rather than only surfacing later in capture.
                do {
                    let composition = try AppComposition.make()
                    try? await composition.queue.resumeAfterAuth()
                } catch {
                    log.error("signIn: composition build failed after auth \(String(describing: error), privacy: .public)")
                }
                status = "Signed in ✓"
                signedInOK = true
            } catch AuthError.signInCancelled {
                log.debug("signIn: cancelled")
                status = "Sign in cancelled."
            } catch {
                log.error("signIn: failed \(String(describing: error), privacy: .public)")
                status = "Sign in failed: \(error)"
            }
            busy = false
            // Hand off only after the last local-state write, so nothing mutates
            // this view once the root swaps it out.
            if signedInOK { onSignedIn() }
        }
    }
}

#Preview {
    SignInView(onSignedIn: {})
}
