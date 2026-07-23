// ABOUTME: Typed accessors over the App Group UserDefaults shared by app and extensions.
// ABOUTME: Holds the server base URL and the include-location toggle (SPEC 4.2, 9).

import Foundation

/// The settings every MindGrapes process on a device must agree on.
///
/// SPEC 4.2 puts the base URL and the location toggle in shared `UserDefaults`
/// rather than in each process's own, so an intent run from the Share Sheet
/// targets the same server as the app.
///
/// `@unchecked Sendable`: the only stored property is a `UserDefaults`, which
/// Foundation documents as thread-safe, and this type adds no state of its own.
public struct SharedDefaults: @unchecked Sendable {
    /// Keys are part of the cross-process contract; renaming one strands the
    /// other side's value with no error anywhere.
    enum Key {
        static let serverBaseURL = "serverBaseURL"
        static let includeLocation = "includeLocation"
    }

    let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Returns `nil` when the App Group is missing from the process's
    /// entitlements, which is also what the host sees under `swift test`.
    public init?(appGroup identifier: String = AppGroup.identifier) {
        guard let defaults = UserDefaults(suiteName: identifier) else { return nil }
        self.init(defaults: defaults)
    }

    /// The server this install is onboarded to, or `nil` before onboarding.
    public var serverConfig: ServerConfig? {
        get {
            guard let string = defaults.string(forKey: Key.serverBaseURL),
                  let url = URL(string: string)
            else { return nil }
            return ServerConfig(baseURL: url)
        }
        nonmutating set {
            defaults.set(newValue?.baseURL.absoluteString, forKey: Key.serverBaseURL)
        }
    }

    /// Whether captures attach a location fix (SPEC 9).
    ///
    /// Defaults to on when unset, which is why the raw object is checked rather
    /// than `bool(forKey:)`: that would report a never-configured install as
    /// having the toggle off.
    public var includeLocation: Bool {
        get {
            guard defaults.object(forKey: Key.includeLocation) != nil else { return true }
            return defaults.bool(forKey: Key.includeLocation)
        }
        nonmutating set {
            defaults.set(newValue, forKey: Key.includeLocation)
        }
    }
}
