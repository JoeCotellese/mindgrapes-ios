// swift-tools-version: 6.2
// ABOUTME: SPM manifest for MindGrapesKit, the shared capture framework.
// ABOUTME: Declares macOS so `swift test` runs on the host with no simulator.

import PackageDescription

let package = Package(
    name: "MindGrapesKit",
    // macOS is here so the unit suite runs on the host toolchain. Nothing in
    // the package should import UIKit; platform-specific work goes behind a
    // protocol seam so the logic stays host-testable.
    platforms: [.iOS(.v26), .watchOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "MindGrapesKit", targets: ["MindGrapesKit"])
    ],
    targets: [
        .target(name: "MindGrapesKit", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(
            name: "MindGrapesKitTests",
            dependencies: ["MindGrapesKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
