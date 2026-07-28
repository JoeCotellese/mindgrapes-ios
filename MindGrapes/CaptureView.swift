// ABOUTME: The capture screen: a focused compose field over one docked bar of capture actions.
// ABOUTME: Every action runs through CaptureIntentRunner, the same path Siri and the Shortcuts take.

import MindGrapesKit
import OSLog
import PhotosUI
import SwiftUI

private let log = Logger(subsystem: "net.cotellese.mindgrapes", category: "capture")

/// Types a note or adds a photo and watches it reach a real `experience_id`.
///
/// The screen owns no pipeline of its own: it builds the shared ``AppComposition``
/// and drives ``CaptureIntentRunner`` — the exact path the capture App Intents
/// take — so "every entry point runs the same code" (SPEC 4.1) is true rather
/// than aspirational. The screen adds only what is UI.
///
/// The layout is the one that won the item-17 design pass: the draft owns the
/// screen and every action lives in a single bar docked at the bottom, within
/// thumb reach of the keyboard the field raises on launch. The bar is a
/// `safeAreaInset` rather than a keyboard toolbar deliberately — a keyboard
/// toolbar disappears with the keyboard, which would strand a user who wants to
/// shoot a photo without typing first.
///
/// There is no mic button: the field is focused from launch, so the system
/// keyboard's own dictation key is always on screen, and a second mic beside it
/// would be duplicate chrome. SPEC 10.1 lists a mic button; this is the one
/// deliberate departure, and adding it back is a single toolbar entry.
struct CaptureView: View {
    /// Called after the user signs out, so the root can return to sign-in.
    var onSignOut: () -> Void = {}

    @State private var text = ""
    @State private var status = CaptureStatus.ready
    @State private var runner: CaptureIntentRunner?
    @State private var drainer: CaptureDrainer?
    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var showSettings = false
    @State private var busy = false
    @FocusState private var composing: Bool
    @Environment(\.scenePhase) private var scenePhase

    /// Whether the draft is something the pipeline would accept. Mirrors the
    /// runner's own check so the send button is dark before the rejection, not
    /// after it.
    private var canSend: Bool {
        !busy && runner != nil && NoteDraft(content: text) != nil
    }

    var body: some View {
        ScrollView {
            TextField("What's on your mind?", text: $text, axis: .vertical)
                .font(.title3)
                .focused($composing)
                .textInputAutocapitalization(.sentences)
                .padding(.horizontal, 20)
                .padding(.top, 12)
        }
        .scrollDismissesKeyboard(.never)
        .safeAreaInset(edge: .bottom, spacing: 0) { captureBar }
        .navigationTitle("Capture")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            // onSignOut flips the root to sign-in, which tears down this view and
            // its sheet together; no separate dismiss needed.
            SettingsView(onSignOut: onSignOut)
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker(
                onCapture: { data in savePhoto(data) },
                onFailure: { status = .unreadableImage }
            )
            .ignoresSafeArea()
        }
        .task { await prepare() }
        .onChange(of: scenePhase) { _, phase in
            // Foregrounding drains anything that backed off while away.
            if phase == .active, drainer != nil { Task { await drain() } }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                // Hold the interlock across the load: an iCloud-backed original can
                // take seconds, and without this the buttons stay live for a second
                // overlapping capture.
                busy = true
                status = .working
                if let data = try? await item.loadTransferable(type: Data.self) {
                    busy = false
                    savePhoto(data)
                } else {
                    status = .unreadableImage
                    busy = false
                }
                photoItem = nil
            }
        }
    }

    // MARK: - The docked bar

    /// Status over actions, pinned to the bottom above the keyboard.
    private var captureBar: some View {
        VStack(spacing: 0) {
            statusLine
            HStack(spacing: 20) {
                // No photoLibrary: argument, so this is the out-of-process picker
                // that needs no photo-library permission prompt.
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Photo", systemImage: "photo.on.rectangle")
                }
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button {
                        showCamera = true
                    } label: {
                        Label("Camera", systemImage: "camera")
                    }
                }
                Spacer()
                Button(action: save) {
                    Label("Save", systemImage: "arrow.up")
                        .font(.headline)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                .disabled(!canSend)
            }
            .labelStyle(.iconOnly)
            .font(.title3)
            .disabled(busy || runner == nil)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(.bar)
    }

    /// One line of state, or a reserved blank so the bar does not jump when a
    /// message arrives.
    private var statusLine: some View {
        HStack(spacing: 6) {
            if status == .working {
                ProgressView().controlSize(.small)
            } else if let symbol = status.symbolName {
                Image(systemName: symbol)
            }
            Text(status.message)
        }
        .font(.caption)
        .foregroundStyle(status.tint)
        .frame(minHeight: 18)
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Pipeline

    /// Builds the shared composition. No network here: discovery is deferred into
    /// the drainer's token closure, so a launch offline still stands the screen up.
    private func prepare() async {
        do {
            let composition = try AppComposition.make()
            self.runner = composition.runner
            self.drainer = composition.drainer
            composing = true
            // Flush anything a prior session left queued: .onChange does not fire
            // for the initial .active, so this is the launch drain.
            await drain()
        } catch AppComposition.CompositionError.notOnboarded {
            status = .notSignedIn
        } catch {
            log.error("prepare failed: \(String(describing: error), privacy: .public)")
            status = .storageUnavailable
        }
    }

    private func save() {
        guard NoteDraft(content: text) != nil, let runner else { return }
        let content = text
        busy = true
        status = .working
        Task {
            let fix = await locationFix()
            let outcome = CaptureStatus(outcome: await runner.captureNote(content, location: fix))
            // Only clear what actually reached durable storage; a rejection leaves
            // the user's words where they can fix them.
            if outcome.draftBecameDurable { text = "" }
            status = outcome
            busy = false
            // The field loses focus to nothing in particular after a send, and a
            // capture app that needs a tap before the next thought is the wrong
            // app. Re-arm it.
            composing = true
        }
    }

    private func savePhoto(_ data: Data) {
        guard let runner else { return }
        busy = true
        status = .working
        Task {
            let fix = await locationFix()
            log.info("capturePhoto: \(data.count, privacy: .public) bytes, location=\(fix != nil, privacy: .public)")
            let outcome = await runner.capturePhoto(data, location: fix)
            log.info("capturePhoto outcome: \(String(describing: outcome), privacy: .public)")
            status = CaptureStatus(outcome: outcome)
            busy = false
        }
    }

    /// The location fix to attach, or `nil` when the toggle is off, permission is
    /// denied, or no fix arrived within the budget. A denied permission turns the
    /// setting off with one explanation rather than prompting on every capture
    /// (SPEC 9). The budget lives in ``LocationProvider``, so a slow fix delays a
    /// capture by at most that budget and never blocks it outright.
    private func locationFix() async -> LocationFix? {
        let defaults = SharedDefaults(appGroup: AppGroup.identifier)
        guard defaults?.includeLocation ?? true else { return nil }
        let fix = await LocationProvider.system().currentFix()
        if fix == nil, LocationPermission.status == .denied {
            defaults?.includeLocation = false
            // The Watch cannot read this App Group, so the value has to be pushed.
            // Without this it reached the wrist only on the next activation or
            // foreground, and a user whose permission was revoked kept capturing
            // from the wrist as though location were still on.
            WatchSessionCoordinator.shared.pushSettings()
            status = .locationOff
        }
        return fix
    }

    /// A foreground flush of anything queued. Not a capture, so it uses the
    /// drainer directly rather than the runner.
    private func drain() async {
        guard let drainer, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let snapshots = try await drainer.drainOnce()
            status = CaptureStatus(
                drainedPending: snapshots.filter { $0.state == .pending || $0.state == .inFlight }.count,
                sawFailure: snapshots.contains { $0.state == .failed },
                sawAuthRequired: snapshots.contains { $0.state == .authRequired },
                drainedAnything: !snapshots.isEmpty
            )
        } catch {
            log.error("drain failed: \(String(describing: error), privacy: .public)")
        }
    }
}
