// ABOUTME: Proves PhotoSpooler downscales captured bytes and writes one spool file the queue can name.
// ABOUTME: Fixtures are drawn in code so the repo carries no binary test assets.

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import MindGrapesKit

@Suite struct PhotoSpoolerTests {
    private func appGroup() throws -> AppGroupContainer {
        let directory = URL.temporaryDirectory.appending(path: "MindGrapesSpoolTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return AppGroupContainer(rootURL: directory)
    }

    @Test func spoolWritesADecodableDerivativeUnderTheServerMaximum() throws {
        let appGroup = try appGroup()
        let filename = try PhotoSpooler.spool(jpeg(width: 3000, height: 2000), into: appGroup)

        let url = appGroup.photoSpoolFileURL(named: filename)
        #expect(FileManager.default.fileExists(atPath: url.path))

        let written = try Data(contentsOf: url)
        let source = try #require(CGImageSourceCreateWithData(written as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let longest = max(props?[kCGImagePropertyPixelWidth] as? Int ?? 0,
                          props?[kCGImagePropertyPixelHeight] as? Int ?? 0)
        #expect(longest == ImageDownscaler.maxPixelDimension)
    }

    @Test func spoolCreatesTheSpoolDirectoryIfMissing() throws {
        // A fresh container has no PhotoSpool dir; spool must not fail on that.
        let appGroup = try appGroup()
        #expect(!FileManager.default.fileExists(atPath: appGroup.photoSpoolURL.path))
        let filename = try PhotoSpooler.spool(jpeg(width: 100, height: 100), into: appGroup)
        #expect(FileManager.default.fileExists(atPath: appGroup.photoSpoolFileURL(named: filename).path))
    }

    @Test func spoolGivesEachCaptureAUniqueFilename() throws {
        let appGroup = try appGroup()
        let a = try PhotoSpooler.spool(jpeg(width: 100, height: 100), into: appGroup)
        let b = try PhotoSpooler.spool(jpeg(width: 100, height: 100), into: appGroup)
        #expect(a != b)
    }

    @Test func spoolRejectsUndecodableBytes() {
        #expect(throws: ImageDownscaleError.self) {
            _ = try PhotoSpooler.spool(Data([0, 1, 2, 3]), into: try appGroup())
        }
    }

    // MARK: - Fixture

    private func jpeg(width: Int, height: Int) -> Data {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = 200; pixels[i + 1] = 50; pixels[i + 2] = 50; pixels[i + 3] = 255
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
        let buffer = NSMutableData()
        let dest = CGImageDestinationCreateWithData(buffer, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        _ = CGImageDestinationFinalize(dest)
        return buffer as Data
    }
}
