// ABOUTME: Wraps VisionKit's DataScannerViewController so onboarding can read the QR on the server's /connect page.
// ABOUTME: Reports the first barcode payload it sees; deciding whether that payload is a Mind Grapes URL is the caller's job.

import SwiftUI
import VisionKit

/// The camera half of onboarding (#20).
///
/// VisionKit rather than a hand-rolled `AVCaptureMetadataOutput`: it brings the
/// viewfinder, the highlight, and the focus handling that a scanner needs and
/// that would otherwise be a few hundred lines of our own.
///
/// The payload is handed up as a raw string. This view knows nothing about Mind
/// Grapes URLs on purpose, so the "is this one of ours" rule lives in one place
/// (`ServerDiscovery.baseURL(fromScannedCode:)`) and stays unit-tested.
struct QRScannerView: UIViewControllerRepresentable {
    /// Called on the first recognized symbol. The caller dismisses.
    let onCode: (String) -> Void
    /// Called when the camera cannot start: permission denied after the sheet
    /// opened, a restriction, or hardware trouble. Without this the user gets a
    /// black rectangle and no idea why.
    let onUnavailable: (String) -> Void

    /// Whether this device has the hardware to scan at all. Deliberately does
    /// **not** consult `isAvailable`, which also goes false on a denied camera
    /// permission: hiding the button in that case would leave the user with no
    /// explanation. Onboarding keeps the button and explains on tap.
    static var isSupported: Bool {
        DataScannerViewController.isSupported
    }

    /// Whether a scan can start right now. False once the camera is denied or
    /// restricted, which is a thing to explain rather than a thing to hide.
    static var isAvailable: Bool {
        DataScannerViewController.isAvailable
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            // One code, once: the first payload ends the scan, so tracking
            // several symbols or highlighting them buys nothing here.
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    /// Scanning starts here, not in `makeUIViewController`: VisionKit wants the
    /// scanner's view on screen before `startScanning()`, and this is the first
    /// callback that can promise it. The failure is reported rather than
    /// swallowed, so a denied camera says so instead of showing black.
    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        guard !scanner.isScanning, !context.coordinator.startFailed else { return }
        do {
            try scanner.startScanning()
        } catch {
            context.coordinator.startFailed = true
            onUnavailable("The camera could not start. Type your brain's address instead.")
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode)
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onCode: (String) -> Void
        /// The scan is one-shot: `didAdd` can fire again while the sheet is
        /// dismissing, and a second payload would reopen a flow already in
        /// flight.
        private var reported = false
        /// Set once `startScanning()` throws, so the repeated
        /// `updateUIViewController` callbacks do not retry it and report the
        /// same failure over and over.
        var startFailed = false

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !reported else { return }
            for case .barcode(let barcode) in addedItems {
                guard let payload = barcode.payloadStringValue else { continue }
                reported = true
                dataScanner.stopScanning()
                onCode(payload)
                return
            }
        }
    }
}
