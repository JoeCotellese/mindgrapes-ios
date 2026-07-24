// ABOUTME: A rough sign-in screen to exercise discovery (#9) and the OAuth flow (#10) by hand.
// ABOUTME: ponytail: throwaway. The real connect/onboarding screen (#16) replaces this wholesale.

import MindGrapesKit
import SwiftUI

/// One field, a Check button, a Sign in button, and a status line. Enough to run
/// the whole Slice 1 sign-in path against a real server; deliberately dumb.
struct SignInView: View {
    @State private var urlText = ""
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
        busy = true
        Task {
            let client = BrainClient(config: ServerConfig(baseURL: base), session: .shared)
            status = switch await client.probeReachability() {
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
                let metadata = try await AuthManager.discoverMetadata(baseURL: base, session: .shared)
                let auth = AuthManager(session: .shared, store: TokenStore(), metadata: metadata)
                try await InteractiveSignIn(auth: auth, web: WebAuthenticationSession()).run()
                status = "Signed in ✓"
            } catch AuthError.signInCancelled {
                status = "Sign in cancelled."
            } catch {
                status = "Sign in failed: \(error)"
            }
            busy = false
        }
    }
}

#Preview {
    SignInView()
}
