// ABOUTME: Smoke test proving the package builds and the suite runs on the host.
// ABOUTME: Replaced by real coverage as issue 2 onward land.

import Testing

@testable import MindGrapesKit

@Test func appGroupIdentifiersAreStable() {
    // These strings appear in entitlements files that are not compiled, so a
    // typo here is only caught by a test that pins them.
    #expect(AppGroup.identifier == "group.net.cotellese.mindgrapes")
    #expect(AppGroup.keychainAccessGroup == "net.cotellese.mindgrapes.shared")
}
