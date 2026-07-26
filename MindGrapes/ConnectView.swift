// ABOUTME: Onboarding (#20): scan the server's QR (or type its address), probe /healthz, run OAuth, then pitch location.
// ABOUTME: Replaces the throwaway SignInView; the sign-in body is carried over from it unchanged in behavior.

import MindGrapesKit
import OSLog
import SwiftUI

private let log = Logger(subsystem: "net.cotellese.mindgrapes", category: "onboarding")

/// The first screen on a fresh install, and the way back after a sign-out.
///
/// Two steps, in the order SPEC 5.1 describes: reach a server and authenticate,
/// then ask for location with the honest pitch. The location step is skipped
/// when iOS has already recorded an answer, since the system prompt only ever
/// appears once per install.
struct ConnectView: View {
    /// Called once the device holds usable credentials and location has been
    /// settled, so the root can show capture.
    let onSignedIn: () -> Void

    private enum Step { case server, location }

    @State private var step: Step = .server
    @State private var urlText: String
    @State private var status: String
    @State private var busy = false
    @State private var scanning = false

    init(onSignedIn: @escaping () -> Void) {
        self.onSignedIn = onSignedIn
        // Pre-fill the last connected server so re-signing in after a sign-out is
        // one tap. A fresh install starts empty: guessing a host here would put
        // words in the user's mouth and make a failed probe read as their fault.
        let stored = SharedDefaults(appGroup: AppGroup.identifier)?.serverConfig?.baseURL.absoluteString
        _urlText = State(initialValue: stored ?? "")
        _status = State(
            initialValue: stored == nil
                ? "Scan the QR on your brain's connect page, or type its address."
                : "Sign in again to keep capturing."
        )
        // The root only shows this screen when the install is not onboarded. If
        // credentials already exist, the missing half is the location answer, so
        // resume at the pitch rather than asking the user to sign in again. That
        // is what makes onboarding survive a background or a relaunch taken
        // while the pitch was on screen: OAuth writes tokens the moment it
        // succeeds, but the pitch is not answered until it is answered.
        _step = State(initialValue: RootView.hasStoredSession() ? .location : .server)
    }

    var body: some View {
        Group {
            switch step {
            case .server: serverStep
            case .location: locationStep
            }
        }
        .padding()
        .sheet(isPresented: $scanning) {
            NavigationStack {
                QRScannerView(onCode: scanned, onUnavailable: cameraFailed)
                    .ignoresSafeArea()
                    .navigationTitle("Scan your brain's QR")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { scanning = false }
                        }
                    }
            }
        }
    }

    // MARK: - Step 1: reach a server and sign in

    private var serverStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("MindGrapes")
                .font(.largeTitle.bold())

            Text("Your memories live on your own server. Point the app at it once.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if QRScannerView.isSupported {
                Button("Scan QR code", systemImage: "qrcode.viewfinder", action: startScanning)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(busy)
            }

            // Manual entry is the documented fallback (SPEC Decision 6), not a
            // hidden last resort: it stays on screen next to the scan button, so
            // a denied camera or an unsupported device is never a dead end.
            Text("Or type the address")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                TextField("brain.example.ts.net", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .onSubmit(connectTyped)

                Button("Connect", action: connectTyped)
                    .buttonStyle(.bordered)
                    .disabled(urlText.isEmpty)
            }
            .disabled(busy)

            if busy { ProgressView() }

            Text(status)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer()
        }
    }

    /// Opens the scanner, or explains why it cannot open. A denied camera is a
    /// thing to say out loud: hiding the button would leave the user guessing,
    /// and manual entry is right there either way.
    private func startScanning() {
        guard QRScannerView.isAvailable else {
            status = "MindGrapes can't use the camera. Turn it on in Settings, or type the address below."
            return
        }
        scanning = true
    }

    /// A scanned symbol. Anything that is not one of our URLs is named as such
    /// here, rather than being probed and reported as a connection problem.
    private func scanned(_ payload: String) {
        // A payload that lands while a connect is already in flight is dropped
        // rather than starting a second probe and a second consent sheet.
        guard !busy else { return }
        scanning = false
        guard let base = ServerDiscovery.baseURL(fromScannedCode: payload) else {
            log.debug("scan: payload is not a Mind Grapes URL")
            status = "That is not a Mind Grapes code. Scan the QR on your brain's connect page."
            return
        }
        urlText = base.absoluteString
        connect(to: base)
    }

    /// The camera died after the sheet opened. Close it and say so, rather than
    /// leaving a black rectangle on screen.
    private func cameraFailed(_ message: String) {
        scanning = false
        status = message
    }

    private func connectTyped() {
        guard let base = ServerDiscovery.normalizedURL(from: urlText) else {
            status = "That is not an address I can use."
            return
        }
        connect(to: base)
    }

    /// A short-fused session for the probe alone.
    ///
    /// `URLSession.shared` waits out its 60-second default, and the likeliest
    /// failure here (a host that resolves but never answers, because the phone
    /// is off the tailnet) would freeze the screen for a full minute before
    /// saying anything. Ten seconds is long enough for a sleepy server and short
    /// enough that the Tailscale hint arrives while the user still cares.
    private static let probeSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration)
    }()

    /// Probe, then sign in. The probe runs first so an unreachable server fails
    /// with an explanation instead of an OAuth sheet that cannot load.
    private func connect(to base: URL) {
        busy = true
        status = "Checking \(base.host() ?? base.absoluteString)…"
        Task {
            let client = BrainClient(config: ServerConfig(baseURL: base), session: ConnectView.probeSession)
            let reachability = await client.probeReachability()
            log.debug("connect: probe \(String(describing: reachability), privacy: .public)")
            switch reachability {
            case .reachable:
                await signIn(to: base)
            case .wrongHost:
                status = "Something answered, but it is not a Mind Grapes server. Check the address."
                busy = false
            case .unreachable:
                // The likeliest real failure by a wide margin: the server sits
                // behind Tailscale (Decision 6), so a phone that is off the
                // tailnet reaches nothing. Naming it beats a generic network
                // error the user has to guess at.
                status = "Can't reach your server. Is Tailscale connected on this phone?"
                busy = false
            }
        }
    }

    /// Carried over from the screen this replaces: discover metadata, run the
    /// consent sheet, persist the server, revive anything the queue parked.
    private func signIn(to base: URL) async {
        var signedInOK = false
        do {
            log.debug("signIn: discovering metadata at \(base.absoluteString, privacy: .public)")
            status = "Discovering…"
            let metadata = try await AuthManager.discoverMetadata(baseURL: base, session: .shared)

            // ponytail: no keychain access group. The shared group is for a
            // future extension (SPEC 5.4); naming it needs provisioning the
            // app does not have yet (-34018 on device).
            let auth = AuthManager(session: .shared, store: TokenStore(accessGroup: nil), metadata: metadata)

            status = "Opening sign-in…"
            try await InteractiveSignIn(auth: auth, web: WebAuthenticationSession()).run()

            // Persist the chosen server so the capture screen (and a future
            // extension) target the same host without re-asking (SPEC 4.2).
            let shared = SharedDefaults(appGroup: AppGroup.identifier)
            let previous = shared?.serverConfig?.baseURL
            shared?.serverConfig = ServerConfig(baseURL: base)
            if previous != base {
                // The composition caches the server it was built against and is
                // keyed on nothing (AppComposition.swift:26), so signing in to a
                // different host without an intervening sign-out would keep
                // draining queued captures to the old one. This is the
                // re-onboarding call site AppComposition.reset() documents.
                AppComposition.reset()
            }
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
        guard signedInOK else { return }

        // iOS shows the location prompt once per install. If it has already been
        // answered there is nothing to pitch, so a re-sign-in goes straight to
        // capture rather than showing a screen whose buttons do nothing.
        if LocationPermission.status == .notDetermined {
            step = .location
        } else {
            onSignedIn()
        }
    }

    // MARK: - Step 2: the location pitch

    private var locationStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "location.circle")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text("Tag memories with where you were")
                .font(.title.bold())

            // The honest pitch (SPEC 9): say what is collected and how coarse it
            // is, so the answer is informed rather than reflexive.
            Text("""
                MindGrapes can note roughly where you made each capture, to the \
                nearest hundred metres or so. It asks only while you are using \
                the app, never in the background, and only when the location \
                toggle on the capture screen is on.

                You can change your mind at any time.
                """)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Turn on location") {
                // Guarded by `busy` because the system prompt only appears once:
                // a second tap while the first is awaiting an answer would build
                // a request that no callback ever resolves.
                busy = true
                Task {
                    let granted = await LocationPermission.request() == .granted
                    finishLocationStep(includeLocation: granted)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .disabled(busy)

            Button("Not now") { finishLocationStep(includeLocation: false) }
                .frame(maxWidth: .infinity)
                .disabled(busy)
        }
    }

    /// Persists the answer before handing off, so the capture screen reads what
    /// this screen collected rather than its own default, and so a relaunch does
    /// not ask again.
    private func finishLocationStep(includeLocation: Bool) {
        let shared = SharedDefaults(appGroup: AppGroup.identifier)
        shared?.includeLocation = includeLocation
        shared?.locationPitchAnswered = true
        // Onboarding is the first time this answer exists, and a Watch paired
        // before sign-in is already running. Push it now rather than leaving the
        // wrist on its conservative default until the next foreground.
        WatchSessionCoordinator.shared.pushSettings()
        busy = false
        onSignedIn()
    }
}

#Preview {
    ConnectView(onSignedIn: {})
}
