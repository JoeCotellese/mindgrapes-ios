// ABOUTME: The testable core of the share extension: maps a shared item to a durable NoteDraft/PhotoDraft.
// ABOUTME: No UIKit here, so the same enqueue the app and Siri use is exercised by swift test (SPEC 4.1).

import Foundation

/// The readable content extracted from a shared web page, mirroring the browser
/// extension's `{title, text}` (mindgrapes-extension). Both fields are optional
/// because a share from a non-browser app carries a URL with no page context.
public struct ReadablePage: Sendable, Hashable {
    public let title: String?
    public let text: String?

    public init(title: String?, text: String?) {
        self.title = title?.nonBlank
        self.text = text?.nonBlank
    }

    /// True when neither a title nor body text survived trimming, so the caller
    /// falls back to the bare URL.
    public var isEmpty: Bool { title == nil && text == nil }
}

/// One thing an iOS share sheet handed us. The extension resolves the
/// `NSExtensionItem` attachments into one of these before touching the Kit.
public enum SharedItem: Sendable {
    /// Plain text selected in another app.
    case text(String)
    /// A URL, with the readable page when the source was a web view (`nil` = bare).
    case url(URL, readable: ReadablePage?)
    /// Raw image bytes, in any format ``ImageDownscaler`` accepts.
    case image(Data)
}

/// Composes the single note `content` string the wire format carries
/// (``CaptureWireEncoder`` sends one `content` field, unlike the browser
/// extension's structured `/capture` body). Pure and separately tested so the
/// wording is pinned without a store.
public enum ShareCaptureComposer {
    /// The note body for a text or URL share, or `nil` for an image (which is not
    /// a note) or when nothing usable was shared.
    ///
    /// Blocks are joined by a blank line: an optional user note leads, then for a
    /// URL the title and URL sit together as a header, then the article text.
    public static func noteContent(for item: SharedItem, note userNote: String?) -> String? {
        var blocks: [String] = []
        if let note = userNote?.nonBlank { blocks.append(note) }

        switch item {
        case .text(let text):
            if let text = text.nonBlank { blocks.append(text) }
        case .url(let url, let readable):
            var header: [String] = []
            if let title = readable?.title { header.append(title) }
            header.append(url.absoluteString)
            blocks.append(header.joined(separator: "\n"))
            if let body = readable?.text { blocks.append(body) }
        case .image:
            return nil
        }

        let joined = blocks.joined(separator: "\n\n")
        return joined.nonBlank
    }

    /// Builds a URL ``SharedItem`` from the browser-style `{url, title, text}` the
    /// share extension's JS preprocessing file returns, applying the bare-URL
    /// fallback. Returns `nil` when there is no usable URL, so the caller can fall
    /// through to another attachment.
    ///
    /// Kept in the Kit, and separately tested, because it is the decision the
    /// extension's framework glue cannot exercise: a page with no readable text
    /// degrades to the bare URL, and a missing or malformed URL is not a capture.
    public static func urlItem(urlString: String?, title: String?, text: String?) -> SharedItem? {
        guard let urlString = urlString?.nonBlank, let url = URL(string: urlString) else { return nil }
        let page = ReadablePage(title: title, text: text)
        return .url(url, readable: page.isEmpty ? nil : page)
    }
}

/// Enqueues a shared item into the durable outbox and stops there.
///
/// Enqueue-only by design (#50): a share extension dies when its sheet dismisses,
/// so it never uploads inline. It writes the App Group SwiftData store and the
/// photo spool the app already owns; delivery happens on the app's next
/// foreground drain. This needs only the App Group entitlement, not the shared
/// Keychain group, so it sidesteps the -34018 blocker entirely. When the
/// background URLSession lands (#21) the extension can hand off for
/// app-never-opened delivery.
public enum ShareCapture {
    public enum Outcome: Sendable, Equatable {
        case note(id: UUID)
        case photo(id: UUID)
        /// Nothing usable was shared, or the image would not decode.
        case rejected(reason: String)
    }

    /// Writes one durable capture for the shared item. Text and URLs become a
    /// note; an image is downscaled, spooled, and becomes a photo whose
    /// description is the user's note or the template fallback (SPEC 7.3), the
    /// same provisional the app's photo path writes before enrichment.
    public static func enqueue(
        _ item: SharedItem,
        note userNote: String?,
        into queue: CaptureQueue,
        appGroup: AppGroupContainer,
        now: Date = Date()
    ) async throws -> Outcome {
        switch item {
        case .text, .url:
            guard let content = ShareCaptureComposer.noteContent(for: item, note: userNote),
                  let draft = NoteDraft(content: content, occurredAt: now)
            else {
                return .rejected(reason: "empty")
            }
            let snapshot = try await queue.enqueue(note: draft, now: now)
            return .note(id: snapshot.id)

        case .image(let data):
            let filename: String
            do {
                filename = try PhotoSpooler.spool(data, into: appGroup)
            } catch {
                return .rejected(reason: "bad_image")
            }
            let description = userNote?.nonBlank ?? PhotoDescription.template(occurredAt: now)
            guard let draft = PhotoDraft(imageFilename: filename, description: description, occurredAt: now) else {
                // Spooled but no record will name it; delete so it is not orphaned
                // (only record-backed spool files are ever reclaimed).
                try? FileManager.default.removeItem(at: appGroup.photoSpoolFileURL(named: filename))
                return .rejected(reason: "bad_image")
            }
            let snapshot = try await queue.enqueue(photo: draft, now: now)
            return .photo(id: snapshot.id)
        }
    }
}
