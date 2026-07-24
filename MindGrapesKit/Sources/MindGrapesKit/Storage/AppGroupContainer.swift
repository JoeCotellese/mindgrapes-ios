// ABOUTME: Resolves the SwiftData store and photo spool paths inside the App Group.
// ABOUTME: The container lookup sits behind a seam so path logic is testable off-device.

import Foundation

/// Supplies the on-disk root of an App Group container.
///
/// A seam, not indirection for its own sake: `swift test` runs on the host,
/// where no App Group exists and the real lookup always answers `nil`. Path
/// construction is the part worth testing, so it is separated from the lookup.
public protocol AppGroupContainerLocating: Sendable {
    func containerURL(forAppGroup identifier: String) -> URL?
}

/// The real lookup, backed by `FileManager`.
public struct SystemAppGroupContainerLocator: AppGroupContainerLocating {
    public init() {}

    public func containerURL(forAppGroup identifier: String) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}

public enum AppGroupContainerError: Error, Sendable, Equatable {
    /// The App Group is missing from the running process's entitlements, or
    /// the process is not sandboxed into one at all.
    case unavailable(identifier: String)
}

/// The directory app, extensions, and the Watch all address (SPEC 4.2).
///
/// One container holds the SwiftData store and the photo spool so a capture
/// made in an extension is visible to the app without any relay.
public struct AppGroupContainer: Sendable, Hashable {
    /// The App Group container root.
    public let rootURL: URL

    /// Builds a container over a known directory. Tests use this; production
    /// code should go through the throwing initializer so a missing entitlement
    /// surfaces instead of silently writing somewhere extensions cannot read.
    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    /// Resolves the container for an App Group, throwing when it is not there.
    public init(
        identifier: String = AppGroup.identifier,
        locator: some AppGroupContainerLocating = SystemAppGroupContainerLocator()
    ) throws {
        guard let root = locator.containerURL(forAppGroup: identifier) else {
            throw AppGroupContainerError.unavailable(identifier: identifier)
        }
        self.init(rootURL: root)
    }

    /// The SwiftData store backing the capture queue (SPEC 8.1).
    public var storeURL: URL {
        rootURL.appending(path: "CaptureQueue.store")
    }

    /// Where downscaled photo derivatives wait for upload (SPEC 7.2 step 5).
    /// Distinct from wherever item 6 puts background-session request bodies:
    /// this file is the capture, that one is a rebuildable envelope.
    public var photoSpoolURL: URL {
        rootURL.appending(path: "PhotoSpool", directoryHint: .isDirectory)
    }

    /// The spool file a ``CaptureRecord/imageFilename`` refers to.
    public func photoSpoolFileURL(named filename: String) -> URL {
        photoSpoolURL.appending(path: filename, directoryHint: .notDirectory)
    }

    /// Creates any directory the container needs. Safe to call repeatedly, and
    /// callable from every process since each one may be the first to run.
    public func prepareDirectories() throws {
        try FileManager.default.createDirectory(
            at: photoSpoolURL,
            withIntermediateDirectories: true
        )
    }
}
