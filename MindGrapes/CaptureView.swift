// ABOUTME: A rough capture screen wired end to end: type a note or pick/shoot a photo, watch it reach a real experience_id.
// ABOUTME: ponytail: throwaway Slice-1/2 HITL screen; the real capture UI (issue 17) replaces it.

import MindGrapesKit
import OSLog
import PhotosUI
import SwiftData
import SwiftUI

private let log = Logger(subsystem: "net.cotellese.mindgrapes", category: "capture")

/// Types a note, taps Save, and watches the drain loop carry it to a real
/// `experience_id`. Builds its own composition from the base URL the sign-in
/// screen persisted, so there is no object graph to thread through the app.
struct CaptureView: View {
    let baseURL: URL

    @State private var text = ""
    @State private var status = "Preparing…"
    @State private var queue: CaptureQueue?
    @State private var drainer: CaptureDrainer?
    @State private var appGroup: AppGroupContainer?
    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false
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
                .disabled(busy || drainer == nil || NoteDraft(content: text) == nil)

            HStack(spacing: 12) {
                // Any typed text becomes the photo's description; otherwise the
                // timestamp template fills in (SPEC 7.3 has no OCR/model until Slice 6).
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
            }
            .disabled(busy || drainer == nil)

            Text(status)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding()
        .navigationTitle("MindGrapes")
        .task { await prepare() }
        .onChange(of: scenePhase) { _, phase in
            // Foregrounding drains anything that backed off while away.
            if phase == .active, drainer != nil { Task { await drain() } }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    savePhoto(data)
                } else {
                    status = "Could not read that photo."
                }
                photoItem = nil
            }
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker { data in savePhoto(data) }
                .ignoresSafeArea()
        }
    }

    /// Stands up the queue, auth, and transport for this server. Discovery is one
    /// GET; the sign-in the user just completed left the tokens in the keychain.
    private func prepare() async {
        do {
            let appGroup = try AppGroupContainer()
            try appGroup.prepareDirectories()
            let container = try ModelContainer(
                for: CaptureRecord.self,
                configurations: ModelConfiguration(url: appGroup.storeURL)
            )
            let queue = CaptureQueue(container: container, appGroup: appGroup)

            let metadata = try await AuthManager.discoverMetadata(baseURL: baseURL, session: .shared)
            // ponytail: accessGroup nil, matching #10's -34018 fix. Slice 1 is a
            // single process; the shared group returns with the extension (Slice 5).
            let auth = AuthManager(session: .shared, store: TokenStore(accessGroup: nil), metadata: metadata)
            let client = BrainClient(config: ServerConfig(baseURL: baseURL), session: .shared)

            self.queue = queue
            self.appGroup = appGroup
            self.drainer = CaptureDrainer(queue: queue, client: client) {
                try await auth.validAccessToken()
            }
            status = "Ready. Type a note, or add a photo."
            // Flush anything a prior session left queued: drainOnce reclaims
            // interrupted records, and .onChange does not fire for the initial
            // .active, so this is the launch drain.
            await drain()
        } catch {
            log.error("prepare failed: \(String(describing: error), privacy: .public)")
            status = "Setup failed: \(error)"
        }
    }

    private func save() {
        guard let draft = NoteDraft(content: text), let queue, let drainer else { return }
        busy = true
        Task {
            do {
                let enqueued = try await queue.enqueue(note: draft)
                text = ""
                status = "Sending…"
                try await drainer.drainOnce()
                let final = try await queue.snapshot(id: enqueued.id)
                status = final.map(describe) ?? "Saved."
            } catch {
                log.error("save failed: \(String(describing: error), privacy: .public)")
                status = "Could not save: \(error)"
            }
            busy = false
        }
    }

    /// Spools the picked or shot image, enqueues a photo capture, and drains it.
    /// Any typed text is reused as the description; otherwise the template fills in.
    private func savePhoto(_ data: Data) {
        guard let queue, let drainer, let appGroup else { return }
        busy = true
        Task {
            do {
                let filename = try PhotoSpooler.spool(data, into: appGroup)
                let description = NoteDraft(content: text)?.content
                    ?? PhotoDescription.template(occurredAt: Date())
                guard let draft = PhotoDraft(imageFilename: filename, description: description) else {
                    status = "Could not prepare that photo."
                    busy = false
                    return
                }
                let enqueued = try await queue.enqueue(photo: draft)
                text = ""
                status = "Sending photo…"
                try await drainer.drainOnce()
                let final = try await queue.snapshot(id: enqueued.id)
                status = final.map(describe) ?? "Saved."
            } catch {
                log.error("save photo failed: \(String(describing: error), privacy: .public)")
                status = "Could not save photo: \(error)"
            }
            busy = false
        }
    }

    private func drain() async {
        guard let drainer, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let snapshots = try await drainer.drainOnce()
            // claimDue returns oldest-first, so the newest capture is last.
            if let latest = snapshots.last { status = describe(latest) }
        } catch {
            log.error("drain failed: \(String(describing: error), privacy: .public)")
            status = "Send failed: \(error)"
        }
    }

    private func describe(_ snapshot: CaptureSnapshot) -> String {
        switch snapshot.state {
        case .succeeded: "Saved ✓ experience \(snapshot.experienceID ?? "?")"
        case .pending: "Queued, will retry (\(snapshot.lastErrorCode ?? "pending"))."
        case .inFlight: "Sending…"
        case .failed: "Failed: \(snapshot.lastErrorCode ?? "error")."
        case .authRequired: "Session expired. Sign in again."
        }
    }
}
