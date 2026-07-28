// ABOUTME: A minimal settings sheet: shows the connected server and signs out.
// ABOUTME: ponytail: Slice-7 subset (#18); recent-captures/queue status and change-server come later.

import MindGrapesKit
import OSLog
import SwiftUI

private let log = Logger(subsystem: "net.cotellese.mindgrapes", category: "settings")

/// The connected server and a sign-out action.
///
/// Sign out drops the tokens but keeps the DCR registration (SPEC 5.3), so
/// re-auth reuses the stored `client_id` without repeating registration, and
/// keeps the server URL so the sign-in screen stays pre-filled. It then clears
/// the process-global composition cache so a re-sign-in builds a fresh graph.
struct SettingsView: View {
    /// Called after the credentials are cleared, so the root can return to
    /// sign-in. The caller dismisses the sheet.
    let onSignOut: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var includeLocation = SharedDefaults(appGroup: AppGroup.identifier)?.includeLocation ?? true

    private var serverURL: String {
        SharedDefaults(appGroup: AppGroup.identifier)?.serverConfig?.baseURL.absoluteString ?? "Not connected"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    Text(serverURL)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Section {
                    // Lives here rather than on the capture screen per SPEC 10.1:
                    // it is a standing preference, and the capture screen is for
                    // the one thing you came to do.
                    Toggle("Include location", isOn: $includeLocation)
                        .onChange(of: includeLocation) { _, on in
                            SharedDefaults(appGroup: AppGroup.identifier)?.includeLocation = on
                            // The Watch cannot read this App Group, so the value has
                            // to be pushed. Without this it reached the wrist only on
                            // the next activation or foreground, and a user who turned
                            // location on and then raised their wrist captured without
                            // one.
                            WatchSessionCoordinator.shared.pushSettings()
                        }
                } footer: {
                    Text("Tags each capture with where you were, so you can ask about places later.")
                }
                Section {
                    Button("Sign out", role: .destructive, action: signOut)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func signOut() {
        Task {
            // Clear the device-global outbox FIRST: its records carry no account
            // identity, so a capture left pending or parked must not survive to be
            // revived and delivered under the next identity's bearer.
            if let composition = try? AppComposition.make() {
                do {
                    try await composition.queue.clearAll()
                } catch {
                    log.error("signOut: clearAll failed \(String(describing: error), privacy: .public)")
                }
            }
            do {
                try TokenStore(accessGroup: nil).deleteTokens()
            } catch {
                // A Keychain failure here is not fatal to the sign-out intent: the
                // cache reset and the root flip still send the user to sign-in, and
                // a fresh sign-in overwrites whatever remained.
                log.error("signOut: deleteTokens failed \(String(describing: error), privacy: .public)")
            }
            AppComposition.reset()
            onSignOut()
        }
    }
}
