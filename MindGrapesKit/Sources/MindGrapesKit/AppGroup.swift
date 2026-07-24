// ABOUTME: Names the App Group and Keychain access group shared by app and extensions.
// ABOUTME: Central so the container paths in issue 2 have one source of truth.

import Foundation

/// Identifiers shared across every MindGrapes process on a device.
///
/// Declared before anything uses them (issue 1) so the provisioning profile
/// carries the entitlements from the first build rather than forcing a
/// signing detour mid-feature.
public enum AppGroup {
    public static let identifier = "group.net.cotellese.mindgrapes"
    public static let keychainAccessGroup = "net.cotellese.mindgrapes.shared"
}
