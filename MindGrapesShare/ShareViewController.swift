// ABOUTME: The MindGrapesShare extension entry point: resolves the shared item and hosts the compose UI.
// ABOUTME: Enqueue-only (#50) — it writes the App Group outbox and reminds the user to open the app to sync.

import MindGrapesKit
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The principal class named by `NSExtension.NSExtensionPrincipalClass`. It reads
/// the share sheet's attachments into a ``SharedItem`` and presents the SwiftUI
/// compose screen; the actual enqueue is the Kit's tested ``ShareCapture``.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        Task { await present() }
    }

    private func present() async {
        let item = await SharedItemResolver.resolve(extensionContext?.inputItems ?? [])
        let model = ShareComposeModel(
            item: item,
            onCancel: { [weak self] in self?.cancel() },
            onDone: { [weak self] in self?.complete() }
        )
        let host = UIHostingController(rootView: ShareComposeView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    private func complete() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    private func cancel() {
        extensionContext?.cancelRequest(withError: NSError(domain: "net.cotellese.mindgrapes.share", code: 0))
    }
}

/// Drives the compose screen: holds the resolved item, runs the enqueue, and
/// tracks whether it has been saved so the view can show the sync reminder.
@MainActor
final class ShareComposeModel: ObservableObject {
    enum Phase: Equatable {
        case composing
        case saving
        case saved
        case failed(String)
        case nothingToSave
    }

    @Published var note: String = ""
    @Published private(set) var phase: Phase

    let item: SharedItem?
    private let onCancel: () -> Void
    private let onDone: () -> Void

    init(item: SharedItem?, onCancel: @escaping () -> Void, onDone: @escaping () -> Void) {
        self.item = item
        self.onCancel = onCancel
        self.onDone = onDone
        self.phase = item == nil ? .nothingToSave : .composing
    }

    /// A short human-readable preview of what is being shared.
    var preview: String {
        switch item {
        case .text(let text): return text
        case .url(_, let readable) where readable?.title != nil: return readable!.title!
        case .url(let url, _): return url.absoluteString
        case .image: return "Image"
        case nil: return ""
        }
    }

    func save() async {
        guard let item else { return }
        phase = .saving
        do {
            let (queue, appGroup) = try ShareComposition.make()
            let outcome = try await ShareCapture.enqueue(item, note: note, into: queue, appGroup: appGroup)
            switch outcome {
            case .note, .photo:
                phase = .saved
            case .rejected(let reason):
                phase = .failed(reason == "bad_image" ? "That image couldn't be saved." : "Nothing to save.")
            }
        } catch {
            phase = .failed("Couldn't reach your MindGrapes storage.")
        }
    }

    func cancel() { onCancel() }
    func done() { onDone() }
}

/// The minimal compose surface: a preview, an optional note, and a save button;
/// after saving it shows the reminder that captures sync when the app is opened.
struct ShareComposeView: View {
    @ObservedObject var model: ShareComposeModel

    var body: some View {
        NavigationStack {
            Form {
                switch model.phase {
                case .composing, .saving:
                    composeBody
                case .saved:
                    savedBody
                case .failed(let message):
                    Section { Label(message, systemImage: "exclamationmark.triangle") }
                case .nothingToSave:
                    Section { Label("There's nothing here to capture.", systemImage: "questionmark.circle") }
                }
            }
            .navigationTitle("MindGrapes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
    }

    @ViewBuilder private var composeBody: some View {
        Section("Sharing to MindGrapes") {
            Text(model.preview).lineLimit(6).foregroundStyle(.secondary)
        }
        Section("Add a note (optional)") {
            TextField("Note", text: $model.note, axis: .vertical).lineLimit(1...4)
        }
    }

    @ViewBuilder private var savedBody: some View {
        Section {
            Label("Saved to your queue.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
        Section {
            // #50 interim behavior: enqueue-only. Delivery happens on the app's
            // next foreground drain (no background upload until #21), so the user
            // is told plainly rather than left thinking it already synced.
            Label("Open MindGrapes to finish syncing.", systemImage: "arrow.up.circle")
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        switch model.phase {
        case .composing, .saving:
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { model.cancel() }
            }
            ToolbarItem(placement: .confirmationAction) {
                if model.phase == .saving {
                    ProgressView()
                } else {
                    Button("Save") { Task { await model.save() } }
                }
            }
        case .saved, .failed, .nothingToSave:
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { model.done() }
            }
        }
    }
}
