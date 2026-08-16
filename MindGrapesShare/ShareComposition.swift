// ABOUTME: Builds the extension process's own CaptureQueue over the shared App Group SwiftData store.
// ABOUTME: A separate process from the app, so it opens its own ModelContainer; SQLite coordinates the file.

import Foundation
import MindGrapesKit
import SwiftData

/// Assembles the durable half of the capture graph for the share extension.
///
/// The extension is a separate process from the app, so the app's "one
/// `ModelContainer` per process" rule (AppComposition) does not reach here: this
/// builds the extension's own container over the same App Group store URL, and
/// SQLite's file coordination handles the app reading the store the extension
/// wrote. No auth, client, or drainer is built — the extension is enqueue-only
/// (#50), so it needs only the queue and the App Group container.
enum ShareComposition {
    static func make() throws -> (CaptureQueue, AppGroupContainer) {
        let appGroup = try AppGroupContainer()
        try appGroup.prepareDirectories()
        let container = try ModelContainer(
            for: CaptureRecord.self,
            configurations: ModelConfiguration(url: appGroup.storeURL)
        )
        let queue = CaptureQueue(container: container, appGroup: appGroup)
        return (queue, appGroup)
    }
}
