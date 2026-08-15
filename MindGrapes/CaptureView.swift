// ABOUTME: The capture screen: a focused compose field over one docked bar of capture actions.
// ABOUTME: Every action runs through CaptureIntentRunner, the same path Siri and the Shortcuts take.

#if canImport(JournalingSuggestions)
import JournalingSuggestions
#endif
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
    /// Called when the user taps the sign-in action on a parked capture, so the
    /// root can show `ConnectView` without waiting for a background/foreground to
    /// re-gate. `ConnectView` revives the parked queue on success (#48).
    var onNeedsSignIn: () -> Void = {}

    @State private var text = ""
    @State private var status = CaptureStatus.ready
    @State private var runner: CaptureIntentRunner?
    @State private var drainer: CaptureDrainer?
    @State private var queue: CaptureQueue?
    @State private var photoItem: PhotosPickerItem?
    /// A moment picked from Journaling Suggestions, staged into the compose field
    /// and waiting on the user's Save. It carries the visit date and coordinate so
    /// ``save`` can stamp the note with when and where the moment happened rather
    /// than now and here — the whole point of #52 — even after the user edits the
    /// prefilled wording. `nil` whenever the field is a plain typed capture. Only
    /// set on a device with the JournalingSuggestions SDK; inert everywhere else.
    @State private var pendingVisit: JournalingMoment?
    @State private var showCamera = false
    @State private var showSettings = false
    /// How many pieces of work hold the interlock, not whether any does.
    ///
    /// A `Bool` was wrong: a foreground drain and a photo load overlap (the
    /// out-of-process picker sends the app through `.inactive` → `.active`, so
    /// the drain starts while `loadTransferable` is still running), and whichever
    /// finished first cleared a flag the other still needed. That re-enabled the
    /// bar under a live capture and let a second one start on top of it.
    @State private var activeWork = 0
    @FocusState private var composing: Bool
    @Environment(\.scenePhase) private var scenePhase

    private var busy: Bool { activeWork > 0 }

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
            // The JournalingSuggestions module ships only in the device SDK, not
            // the Simulator's, so the whole entry point compiles out on Simulator
            // (where the picker cannot run anyway) and is gated at runtime on a
            // real device by the availability seam. The picker is self-presenting:
            // it draws this label as its button and opens Apple's sheet on tap.
            #if canImport(JournalingSuggestions)
            if JournalingSuggestionsAvailability.isSupported {
                ToolbarItem(placement: .topBarTrailing) {
                    JournalingSuggestionsPicker {
                        // text.badge.plus, not a calendar glyph: these commit as
                        // durable dated text breadcrumbs, and calendar.* reads as
                        // "add a calendar event", the wrong mental model (#52).
                        Label("Add from Journaling Suggestions", systemImage: "text.badge.plus")
                    } onCompletion: { suggestion in
                        // The picker hands the suggestion back on the main actor,
                        // but JournalingSuggestion is not Sendable and the adapter
                        // reads it off-actor. The picker calls this once and never
                        // touches the suggestion again, so the single hop is safe;
                        // nonisolated(unsafe) states that at the one point the
                        // compiler cannot prove it.
                        nonisolated(unsafe) let picked = suggestion
                        if let moment = await journalingMoment(from: picked) {
                            prefill(with: moment)
                        } else {
                            // A picked suggestion we breadcrumb nothing from (no
                            // date, or no place/title) still gets an answer rather
                            // than a silent no-op.
                            status = .suggestionNotUsable
                        }
                    }
                    .accessibilityHint("Opens Apple's picker to add moments to your memory")
                }
            }
            #endif
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            // Coming back from a sheet should land on a ready keyboard, same as
            // launch. Gated on the capture in flight rather than on `busy`: a
            // foreground drain also holds the interlock and never re-arms focus,
            // so `!busy` left the keyboard down for the length of a network pass
            // on any launch with a backlog.
            if status != .working { composing = true }
        } content: {
            // onSignOut flips the root to sign-in, which tears down this view and
            // its sheet together; no separate dismiss needed.
            SettingsView(onSignOut: onSignOut)
        }
        .sheet(isPresented: $showCamera) {
            // savePhoto re-arms focus on the capture path; this covers a cancel,
            // which runs neither callback.
            if status != .working { composing = true }
        } content: {
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
        .onChange(of: text) { _, new in
            // Emptying the field drops any staged visit: whatever is typed next is a
            // fresh capture at today and here, not that suggestion's date and place.
            if new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { pendingVisit = nil }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                // Hold the interlock across the load: an iCloud-backed original can
                // take seconds, and without this the buttons stay live for a second
                // overlapping capture.
                activeWork += 1
                status = .working
                let data = try? await item.loadTransferable(type: Data.self)
                if let data {
                    // Hand off before releasing, so the count never dips to zero
                    // between the two holders. It cannot today (no suspension
                    // point separates them), but one inserted `await` would
                    // re-open the bar under a live capture.
                    savePhoto(data)
                } else {
                    status = .unreadableImage
                    composing = true
                }
                activeWork -= 1
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
            // The message and its icon read as one VoiceOver element; the sign-in
            // action must stay a separate, tappable element, so the combine is
            // scoped to this inner group rather than the whole line.
            HStack(spacing: 6) {
                if status.isBusy {
                    ProgressView().controlSize(.small)
                } else if let symbol = status.symbolName {
                    Image(systemName: symbol)
                }
                Text(status.message)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(status.message)
            // At rest the message is empty, and without this VoiceOver still stops
            // on a focusable element that says nothing.
            .accessibilityHidden(status == .ready)

            // The one interactive escape from a parked or signed-out capture
            // screen (#48). Tinted rather than inheriting the line's red so it
            // reads as an action, not more of the warning. The 44pt hit frame and
            // contentShape give the HIG-minimum tap target the caption glyph alone
            // would not; it lifts the status row's height only in the auth states.
            if status.offersSignIn {
                Button(action: onNeedsSignIn) {
                    Text("Sign in")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tint)
            }
        }
        .font(.caption)
        .foregroundStyle(status.tint)
        .frame(minHeight: 18)
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .onChange(of: status) { _, new in
            // A sighted user sees the line change. Nothing announced it otherwise,
            // so a VoiceOver user tapped Save and got no confirmation at all.
            guard !new.isBusy, new != .ready else { return }
            AccessibilityNotification.Announcement(new.message).post()
        }
    }

    // MARK: - Pipeline

    /// Builds the shared composition. No network here: discovery is deferred into
    /// the drainer's token closure, so a launch offline still stands the screen up.
    private func prepare() async {
        do {
            let composition = try AppComposition.make()
            self.runner = composition.runner
            self.drainer = composition.drainer
            self.queue = composition.queue
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
        // A moment staged from Journaling Suggestions carries its own when and
        // where. Captured before the await so a foreground drain cannot clear it
        // mid-send; consumed only once this save reaches durable storage.
        let staged = pendingVisit
        activeWork += 1
        status = .working
        Task {
            defer {
                activeWork -= 1
                // The field loses focus to nothing in particular after a send, and
                // a capture app that needs a tap before the next thought is the
                // wrong app. Re-arm it.
                composing = true
            }
            let outcome: CaptureStatus
            if let staged {
                // Stamp the visit date and the suggestion's coordinate, not now and
                // the current fix — "when did we see the David" has to answer with
                // the day of the visit (#52). This holds even though the user may
                // have reworded the prefilled text; the date and place are the
                // moment's, the words are theirs. No location toggle applies: the
                // user is not here now, so there is nothing to turn off.
                let fix = staged.coordinate.map { LocationFix(coordinate: $0, placeLabel: nil) }
                outcome = CaptureStatus(outcome: await runner.captureNote(content, location: fix, now: staged.date))
            } else {
                let (fix, locationJustDenied) = await locationFix()
                let raw = CaptureStatus(outcome: await runner.captureNote(content, location: fix))
                outcome = raw.resolving(locationJustDenied: locationJustDenied)
            }
            // Take back only what reached durable storage. The field stays editable
            // during the send and the screen re-arms focus to invite exactly that,
            // so `text = ""` would delete whatever was typed while waiting — and
            // leaving the sent words in place would get them captured twice on the
            // next tap. Dropping the prefix does neither. A mid-string edit falls
            // through and keeps everything, which is the safe direction.
            if outcome.draftBecameDurable {
                if text.hasPrefix(content) { text.removeFirst(content.count) }
                // The staged visit is spent; the next note is a plain capture again.
                pendingVisit = nil
            }
            status = outcome
        }
    }

    private func savePhoto(_ data: Data) {
        guard let runner else { return }
        activeWork += 1
        status = .working
        Task {
            defer {
                activeWork -= 1
                // Returning from the picker or the camera leaves the field
                // unfocused, and the next thought should not need a tap either.
                composing = true
            }
            let (fix, locationJustDenied) = await locationFix()
            log.info("capturePhoto: \(data.count, privacy: .public) bytes, location=\(fix != nil, privacy: .public)")
            let outcome = await runner.capturePhoto(data, location: fix)
            log.info("capturePhoto outcome: \(String(describing: outcome), privacy: .public)")
            status = CaptureStatus(outcome: outcome).resolving(locationJustDenied: locationJustDenied)
        }
    }

    #if canImport(JournalingSuggestions)
    /// Drops a picked suggestion's breadcrumb text into the compose field for the
    /// user to review and edit before saving, rather than committing it silently
    /// (#52). The visit date and coordinate ride along in ``pendingVisit`` so
    /// ``save`` can stamp them even after the wording is edited.
    ///
    /// Only fills an empty field: the field is focused-empty at launch, so this is
    /// the usual case, and overwriting a thought the user is mid-way through typing
    /// would lose it. A pick onto a non-empty field is refused with a nudge instead.
    /// A suggestion that carries nothing we breadcrumb reports that, so a tap is
    /// never a silent no-op.
    ///
    /// This replaces the earlier auto-commit path. The Kit's ``JournalingCommit``
    /// and the ``CaptureStatus/momentsAdded(count:)`` copy remain for Phase 5, where
    /// a system notification commits a moment with no compose field in the loop.
    private func prefill(with moment: JournalingMoment) {
        guard let draft = moment.noteDraft() else {
            // Mapped, but its text was blank — nothing to file under.
            log.error("prefill: moment.noteDraft() was nil, nothing to prefill")
            status = .suggestionNotUsable
            return
        }
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = .suggestionNeedsEmptyField
            return
        }
        text = draft.content
        pendingVisit = moment
        status = .ready
        composing = true
    }
    #endif

    /// The location fix to attach, and whether this call is what turned the
    /// setting off.
    ///
    /// The fix is `nil` when the toggle is off, permission is denied, or no fix
    /// arrived within the budget. A denied permission turns the setting off with
    /// one explanation rather than prompting on every capture (SPEC 9); the
    /// caller owns whether that explanation reaches the screen, because it also
    /// owns the outcome competing for the same line. The budget lives in
    /// ``LocationProvider``, so a slow fix delays a capture by at most that
    /// budget and never blocks it outright.
    private func locationFix() async -> (fix: LocationFix?, justDenied: Bool) {
        let defaults = SharedDefaults(appGroup: AppGroup.identifier)
        guard defaults?.includeLocation ?? true else { return (nil, false) }
        let fix = await LocationProvider.system().currentFix()
        guard fix == nil, LocationPermission.status == .denied else { return (fix, false) }
        defaults?.includeLocation = false
        // The Watch cannot read this App Group, so the value has to be pushed.
        // Without this it reached the wrist only on the next activation or
        // foreground, and a user whose permission was revoked kept capturing
        // from the wrist as though location were still on.
        WatchSessionCoordinator.shared.pushSettings()
        return (nil, true)
    }

    /// A foreground flush of anything queued. Not a capture, so it uses the
    /// drainer directly rather than the runner.
    ///
    /// The resulting status is derived from the queue rather than from the pass:
    /// a pass sees only what was due, so backoff and contention both look like an
    /// empty queue from inside it. See ``CaptureStatus/init(outstanding:parked:failedThisPass:deliveredThisPass:)``.
    private func drain() async {
        guard let drainer, let queue, !busy else { return }
        // What the screen was saying before the sweep. A drain is background news
        // and must not be able to erase foreground news the user has not read yet.
        let previous = status
        activeWork += 1
        status = .syncing
        defer { activeWork -= 1 }
        do {
            let drained = try await drainer.drainOnce()
            let all = try await queue.allSnapshots()
            let swept = CaptureStatus(
                outstanding: all.filter { $0.state == .pending || $0.state == .inFlight }.count,
                parked: all.contains { $0.state == .authRequired },
                failedThisPass: drained.contains { $0.state == .failed },
                deliveredThisPass: drained.contains { $0.state == .succeeded }
            )
            // A quiet sweep says nothing rather than blanking the line: the user's
            // last capture may have failed, and `failedThisPass` is pass-scoped by
            // design, so that news exists nowhere else until the recent-captures
            // list ships (issue filed).
            status = swept == .ready ? previous : swept
        } catch {
            log.error("drain failed: \(String(describing: error), privacy: .public)")
            // Put back what was on screen. Leaving `.syncing` would hang the
            // spinner for the session; clearing to `.ready` would silently drop a
            // capture failure the user had not read.
            status = previous
        }
    }
}
