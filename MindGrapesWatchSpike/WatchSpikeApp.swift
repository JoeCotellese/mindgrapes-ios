// ABOUTME: Throwaway watchOS app answering one question: can the OAuth passkey ceremony finish on the wrist?
// ABOUTME: Not shipping code. Delete this target once SPEC 15 question 1 has an answer.

import MindGrapesKit
import SwiftUI

/// The dev server to sign in against. Edit this, run on a **real Apple Watch**
/// (the simulator has no passkey support, so a simulator run proves nothing
/// about the ceremony), and read the status line.
///
/// The spike deliberately does no onboarding UI: typing a URL on a watch is its
/// own problem, and it is not the question being asked here.
private let serverURL = URL(string: "http://localhost:8000")!

@main
struct WatchSpikeApp: App {
    var body: some Scene {
        WindowGroup {
            SpikeView()
        }
    }
}

/// One button, one status line. The status text is the experiment's output, so
/// it reports which step failed rather than a single "it didn't work".
struct SpikeView: View {
    @State private var status = "Ready"
    @State private var running = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text(status)
                    .font(.footnote)
                    .multilineTextAlignment(.center)

                Button("Try sign-in") {
                    Task { await signIn() }
                }
                .disabled(running)
            }
            .padding()
        }
    }

    private func signIn() async {
        running = true
        defer { running = false }

        do {
            status = "Discovering…"
            let metadata = try await AuthManager.discoverMetadata(baseURL: serverURL, session: .shared)

            // Its own client name, per SPEC 5.5: the Watch registers separately so
            // revoking it on /connect/clients cannot sign the phone out. The spike
            // says "Spike" so a real Watch client can register later without
            // colliding with this experiment's registration.
            status = "Registering…"
            let auth = AuthManager(
                session: .shared,
                store: TokenStore(accessGroup: nil),
                metadata: metadata,
                clientName: "MindGrapes Watch Spike"
            )

            status = "Opening consent…"
            let signIn = InteractiveSignIn(auth: auth, web: WatchWebAuthenticationSession())
            try await signIn.run()

            status = "PASSKEY CEREMONY COMPLETED. Phase 3 is a feature, not a server negotiation."
        } catch AuthError.signInCancelled {
            // Ambiguous on purpose: watchOS reports both a user dismissal and a
            // refusal to present the sheet this way. Which one it was is the whole
            // finding, so say so rather than log "cancelled" and move on.
            status = "Cancelled or never presented. If no sheet appeared, ASWebAuthenticationSession will not present here — that is the RFC 8628 answer."
        } catch {
            status = "Failed: \(error)"
        }
    }
}
