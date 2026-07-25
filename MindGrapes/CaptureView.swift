// ABOUTME: A rough capture screen: type a note or pick/shoot a photo, sent through the same runner Siri uses.
// ABOUTME: ponytail: throwaway Slice-1/2 HITL screen; the real capture UI (issue 17) replaces it.

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
/// than aspirational. The screen adds only what is UI: the location toggle and a
/// status line.
struct CaptureView: View {
    /// Called after the user signs out, so the root can return to sign-in.
    var onSignOut: () -> Void = {}

    @State private var text = ""
    @State private var status = "Preparing…"
    @State private var runner: CaptureIntentRunner?
    @State private var drainer: CaptureDrainer?
    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var showSettings = false
    @State private var includeLocation = true
    @State private var busy = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Capture a note")
                .font(.title2.bold())

            TextField("What's on your mind?", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)

            Button("Save", action: save)
                .buttonStyle(.borderedProminent)
                .disabled(busy || runner == nil || NoteDraft(content: text) == nil)

            HStack(spacing: 12) {
                // No photoLibrary: argument, so this is the out-of-process picker
                // that needs no photo-library permission prompt. The photo's
                // description is the timestamp template (typed captions are the
                // real capture UI's job, issue 17).
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
            }
            .disabled(busy || runner == nil)

            Toggle("Include location", isOn: $includeLocation)
                .onChange(of: includeLocation) { _, on in
                    SharedDefaults(appGroup: AppGroup.identifier)?.includeLocation = on
                }

            Text(status)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding()
        .navigationTitle("MindGrapes")
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
            SettingsView(onSignOut: {
                showSettings = false
                onSignOut()
            })
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
                status = "Reading photo…"
                if let data = try? await item.loadTransferable(type: Data.self) {
                    busy = false
                    savePhoto(data)
                } else {
                    status = "Could not read that photo."
                    busy = false
                }
                photoItem = nil
            }
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker(
                onCapture: { data in savePhoto(data) },
                onFailure: { status = "Could not read that photo." }
            )
            .ignoresSafeArea()
        }
    }

    /// Builds the shared composition. No network here: discovery is deferred into
    /// the drainer's token closure, so a launch offline still stands the screen up.
    private func prepare() async {
        do {
            let composition = try AppComposition.make()
            self.runner = composition.runner
            self.drainer = composition.drainer
            self.includeLocation = SharedDefaults(appGroup: AppGroup.identifier)?.includeLocation ?? true
            status = "Ready. Type a note, or add a photo."
            // Flush anything a prior session left queued: .onChange does not fire
            // for the initial .active, so this is the launch drain.
            await drain()
        } catch AppComposition.CompositionError.notOnboarded {
            status = "Sign in first, then reopen capture."
        } catch {
            log.error("prepare failed: \(String(describing: error), privacy: .public)")
            status = "Couldn't open local storage. Try reopening the app."
        }
    }

    private func save() {
        guard NoteDraft(content: text) != nil, let runner else { return }
        let content = text
        busy = true
        Task {
            let fix = await locationFix()
            let outcome = await runner.captureNote(content, location: fix)
            if case .rejected = outcome {} else { text = "" }
            status = describe(outcome)
            busy = false
        }
    }

    private func savePhoto(_ data: Data) {
        guard let runner else { return }
        busy = true
        Task {
            let fix = await locationFix()
            log.info("capturePhoto: \(data.count, privacy: .public) bytes, location=\(fix != nil, privacy: .public)")
            let outcome = await runner.capturePhoto(data, location: fix)
            log.info("capturePhoto outcome: \(String(describing: outcome), privacy: .public)")
            status = describe(outcome)
            busy = false
        }
    }

    /// The location fix to attach, or `nil` when the toggle is off, permission is
    /// denied, or no fix arrived within the budget. A denied permission flips the
    /// toggle off with one explanation rather than prompting on every capture
    /// (SPEC 9). The budget lives in ``LocationProvider``, so a slow fix delays a
    /// capture by at most that budget and never blocks it outright.
    private func locationFix() async -> LocationFix? {
        guard includeLocation else { return nil }
        let fix = await LocationProvider.system().currentFix()
        if fix == nil, LocationPermission.status == .denied {
            // Flipping the toggle fires its onChange, which persists it; no need
            // to write SharedDefaults again here.
            includeLocation = false
            status = "Location is off. Turn it on in Settings to tag captures."
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
            if let latest = snapshots.last {
                status = latest.state == .succeeded ? "Synced ✓" : "Some captures are still pending."
            }
        } catch {
            log.error("drain failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func describe(_ outcome: CaptureOutcome) -> String {
        switch outcome {
        case .confirmed(let experienceID): "Saved ✓ experience \(experienceID)"
        case .queued: "Saved. It'll sync when you're online."
        case .needsSignIn: "Saved. Sign in again to send it."
        case .failed: "Saved, but the server rejected it."
        case .rejected(let reason): reason == "empty" ? "Nothing to save." : "Could not save that (\(reason))."
        }
    }
}
