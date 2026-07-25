// ABOUTME: Covers App Group path construction and the shared defaults accessors.
// ABOUTME: Uses an injected locator because the host has no real App Group container.

import Foundation
import Testing

@testable import MindGrapesKit

/// A locator that answers with a directory the test controls.
private struct StubLocator: AppGroupContainerLocating {
    let expectedIdentifier: String
    let rootURL: URL?

    func containerURL(forAppGroup identifier: String) -> URL? {
        identifier == expectedIdentifier ? rootURL : nil
    }
}

private func makeTemporaryRoot() throws -> URL {
    let root = URL.temporaryDirectory.appending(path: "MindGrapesGroup-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

// MARK: - Path construction

@Test func containerResolvesItsPathsInsideTheAppGroupRoot() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let container = try AppGroupContainer(
        identifier: AppGroup.identifier,
        locator: StubLocator(expectedIdentifier: AppGroup.identifier, rootURL: root)
    )

    #expect(container.rootURL == root)
    #expect(container.storeURL.deletingLastPathComponent().path == root.path)
    #expect(container.storeURL.lastPathComponent == "CaptureQueue.store")
    #expect(container.photoSpoolURL.deletingLastPathComponent().path == root.path)
    #expect(container.photoSpoolURL.lastPathComponent == "PhotoSpool")
}

@Test func spoolFilesResolveInsideTheSpoolDirectory() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let container = AppGroupContainer(rootURL: root)

    let file = container.photoSpoolFileURL(named: "A1B2.jpg")
    #expect(file.deletingLastPathComponent().path == container.photoSpoolURL.path)
    #expect(file.lastPathComponent == "A1B2.jpg")
    #expect(file.path.hasPrefix(root.path))
}

@Test func containerThrowsWhenTheAppGroupIsUnavailable() {
    // What the host actually sees, and what a mis-provisioned build would see:
    // no container. It must be a clear error, not a crash or a silent fallback
    // to a per-process directory that extensions could never read.
    let locator = StubLocator(expectedIdentifier: AppGroup.identifier, rootURL: nil)
    #expect(throws: AppGroupContainerError.unavailable(identifier: "group.other")) {
        try AppGroupContainer(identifier: "group.other", locator: locator)
    }
}

@Test func preparingTheSpoolDirectoryIsIdempotent() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let container = AppGroupContainer(rootURL: root)

    try container.prepareDirectories()
    try container.prepareDirectories()

    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: container.photoSpoolURL.path, isDirectory: &isDirectory))
    #expect(isDirectory.boolValue)
}

@Test func appGroupContainerIsSendable() {
    func requireSendable<T: Sendable>(_: T.Type) {}
    requireSendable(AppGroupContainer.self)
    requireSendable(AppGroupContainerError.self)
    requireSendable(SharedDefaults.self)
}

// MARK: - Shared defaults

private func withTemporaryDefaults(_ body: (SharedDefaults) throws -> Void) throws {
    let suiteName = "net.cotellese.mindgrapes.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    try body(SharedDefaults(defaults: defaults))
}

@Test func serverConfigRoundTripsThroughSharedDefaults() throws {
    try withTemporaryDefaults { shared in
        #expect(shared.serverConfig == nil)

        let url = try #require(URL(string: "https://brain.example.ts.net"))
        shared.serverConfig = ServerConfig(baseURL: url)
        #expect(shared.serverConfig?.baseURL == url)

        shared.serverConfig = nil
        #expect(shared.serverConfig == nil)
    }
}

@Test func locationToggleDefaultsToOn() throws {
    // SPEC 9: default on, set during onboarding when permission is requested.
    // An unset key must read as on, not as the `Bool` zero value.
    try withTemporaryDefaults { shared in
        #expect(shared.includeLocation)
        shared.includeLocation = false
        #expect(shared.includeLocation == false)
        shared.includeLocation = true
        #expect(shared.includeLocation)
    }
}

@Test func theLocationPitchStartsUnanswered() throws {
    // Onboarding (#20) is "has credentials AND has answered the pitch". An unset
    // key must read as unanswered, so a fresh install still gets asked; reading
    // it as answered would silently restore the ambush-on-first-capture the
    // pitch exists to replace.
    try withTemporaryDefaults { shared in
        #expect(shared.locationPitchAnswered == false)
        shared.locationPitchAnswered = true
        #expect(shared.locationPitchAnswered)
    }
}

@Test func sharedDefaultsKeysAreStable() throws {
    // These keys are written by the app and read by every extension; renaming
    // one silently strands the other side's value.
    try withTemporaryDefaults { shared in
        let url = try #require(URL(string: "https://brain.example.ts.net"))
        shared.serverConfig = ServerConfig(baseURL: url)
        shared.includeLocation = false

        #expect(shared.defaults.string(forKey: "serverBaseURL") == url.absoluteString)
        #expect(shared.defaults.object(forKey: "includeLocation") as? Bool == false)
    }
}
