// ABOUTME: Turns the share sheet's NSExtensionItem attachments into a Kit SharedItem.
// ABOUTME: Prefers the Safari JS-extracted readable page, then image, then bare URL, then plain text.

import Foundation
import MindGrapesKit
import UIKit
import UniformTypeIdentifiers

/// Reads the first usable attachment out of the share sheet.
///
/// Order is deliberate: a Safari share carries both the JS preprocessing results
/// (a readable page) and a bare URL, so the readable page is checked first to
/// match the browser extension. A URL from a non-web app has no page context and
/// falls through to the bare-URL case.
@MainActor
enum SharedItemResolver {
    static func resolve(_ inputItems: [Any]) async -> SharedItem? {
        let providers = (inputItems as? [NSExtensionItem])?.flatMap { $0.attachments ?? [] } ?? []

        // 1. Safari web page: JS preprocessing results {url, title, text}.
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier) {
            if let data = await loadData(provider, .propertyList),
               let readable = readablePage(from: data) {
                return readable
            }
        }

        // 2. Image bytes.
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            if let data = await loadData(provider, .image) {
                return .image(data)
            }
        }

        // 3. Bare URL (from a non-web app, or Safari with no readable page).
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = await loadURL(provider) {
                return .url(url, readable: nil)
            }
        }

        // 4. Plain text.
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
            if let text = await loadString(provider) {
                return .text(text)
            }
        }

        return nil
    }

    /// Builds a URL SharedItem from the JS preprocessing results, which arrive as a
    /// serialized property list keyed under `NSExtensionJavaScriptPreprocessingResultsKey`
    /// (or, on some paths, as the results dictionary itself).
    private static func readablePage(from data: Data) -> SharedItem? {
        guard let outer = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        let results = (outer[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any]) ?? outer
        return ShareCaptureComposer.urlItem(
            urlString: results["url"] as? String,
            title: results["title"] as? String,
            text: results["text"] as? String
        )
    }

    /// The current data-representation load, bridged to async.
    private static func loadData(_ provider: NSItemProvider, _ type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(for: type) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    /// The current typed-object load for a URL, bridged to async.
    private static func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }

    /// The current typed-object load for text, bridged to async.
    private static func loadString(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                continuation.resume(returning: object as? String)
            }
        }
    }
}
