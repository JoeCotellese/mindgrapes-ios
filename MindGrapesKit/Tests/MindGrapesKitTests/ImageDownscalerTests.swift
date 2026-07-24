// ABOUTME: Covers the photo downscale transform: bounds, orientation, formats, failures.
// ABOUTME: Fixtures are drawn in code so the repo carries no binary test assets.

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import MindGrapesKit

// MARK: - Bounds

@Test func downscaleFitsTheLongestSideToTheServerMaximum() throws {
    let source = encoded(markerImage(width: 3000, height: 2000), as: .jpeg)
    let output = try ImageDownscaler.downscale(source)
    let raster = try #require(Raster(output))
    #expect(raster.width == ImageDownscaler.maxPixelDimension)
    #expect(raster.height <= ImageDownscaler.maxPixelDimension)
}

@Test func downscaleFitsAPortraitLongestSideToo() throws {
    let source = encoded(markerImage(width: 2000, height: 3000), as: .jpeg)
    let output = try ImageDownscaler.downscale(source)
    let raster = try #require(Raster(output))
    #expect(raster.height == ImageDownscaler.maxPixelDimension)
    #expect(raster.width <= ImageDownscaler.maxPixelDimension)
}

@Test func downscaleNeverUpscalesAnImageAlreadyWithinBounds() throws {
    let source = encoded(markerImage(width: 800, height: 600), as: .jpeg)
    let output = try ImageDownscaler.downscale(source)
    let raster = try #require(Raster(output))
    #expect(raster.width == 800)
    #expect(raster.height == 600)
}

@Test func downscaleLeavesAnImageExactlyAtTheMaximumAlone() throws {
    let source = encoded(markerImage(width: 1024, height: 768), as: .jpeg)
    let output = try ImageDownscaler.downscale(source)
    let raster = try #require(Raster(output))
    #expect(raster.width == 1024)
    #expect(raster.height == 768)
}

/// Aspect ratio survives to within one pixel of the exact proportional size.
///
/// One pixel is the whole tolerance: ImageIO scales the longest side to the
/// requested maximum and rounds the other, so the only permitted deviation is
/// that rounding step. A percentage tolerance would hide a genuinely wrong
/// transform on a very elongated image.
@Test(arguments: [
    (3000, 2000), (2000, 3000), (4032, 3024), (1600, 900), (900, 1600), (2048, 512),
])
func downscaleKeepsTheAspectRatioWithinOnePixel(width: Int, height: Int) throws {
    let output = try ImageDownscaler.downscale(encoded(markerImage(width: width, height: height), as: .jpeg))
    let raster = try #require(Raster(output))
    let longest = max(width, height)
    let scale = Double(ImageDownscaler.maxPixelDimension) / Double(longest)
    let expectedWidth = Int((Double(width) * scale).rounded())
    let expectedHeight = Int((Double(height) * scale).rounded())
    #expect(abs(raster.width - expectedWidth) <= 1)
    #expect(abs(raster.height - expectedHeight) <= 1)
}

// MARK: - Degenerate geometry

@Test func downscaleHandlesASinglePixelImage() throws {
    let output = try ImageDownscaler.downscale(encoded(markerImage(width: 1, height: 1), as: .png))
    let raster = try #require(Raster(output))
    #expect(raster.width == 1)
    #expect(raster.height == 1)
}

/// An aspect ratio extreme enough that the short side rounds toward zero.
///
/// 10 / 4000 * 1024 is 2.56, so a truncating implementation would still be
/// safe here, but the same arithmetic on a 4000x1 image would not be. The
/// assertion that matters is that neither dimension reaches zero, because a
/// zero-dimension `CGImage` cannot be encoded and the failure would surface as
/// a nil destination rather than a bounds problem.
@Test(arguments: [(4000, 10), (10, 4000), (4000, 1), (1, 4000)])
func downscaleKeepsBothDimensionsPositiveOnExtremeAspectRatios(width: Int, height: Int) throws {
    let output = try ImageDownscaler.downscale(encoded(markerImage(width: width, height: height), as: .png))
    let raster = try #require(Raster(output))
    #expect(raster.width >= 1)
    #expect(raster.height >= 1)
    #expect(max(raster.width, raster.height) == ImageDownscaler.maxPixelDimension)
}

// MARK: - Formats

/// Every format SPEC 6.3 lists the server as accepting, minus WebP.
///
/// WebP is decode-only in ImageIO, so it cannot be produced on the host and is
/// covered separately by ``downscaleAcceptsWebP``.
@Test(arguments: [UTType.jpeg, .png, .gif, .tiff, .bmp, .heic])
func downscaleAcceptsEveryFormatTheServerAccepts(type: UTType) throws {
    let source = encoded(markerImage(width: 1500, height: 1000), as: type)
    let output = try ImageDownscaler.downscale(source)
    let raster = try #require(Raster(output))
    #expect(raster.width == ImageDownscaler.maxPixelDimension)
    #expect(output.count <= ImageDownscaler.byteCeiling)
    #expect(raster.corner(.topLeft).isCloseTo(.red))
}

/// WebP is the one accepted format ImageIO cannot write.
///
/// `CGImageDestinationCopyTypeIdentifiers()` has no WebP entry on macOS, iOS,
/// or watchOS, so this 96-byte lossless fixture is embedded as base64 rather
/// than drawn. Base64 rather than a committed binary because the package has no
/// resources declaration and the fixture is smaller than the manifest change
/// would be. It carries the same marker pattern the drawn fixtures use.
@Test func downscaleAcceptsWebP() throws {
    let source = try #require(Data(base64Encoded: markerWebPBase64))
    let output = try ImageDownscaler.downscale(source)
    let raster = try #require(Raster(output))
    #expect(raster.width == 96)
    #expect(raster.height == 64)
    #expect(raster.corner(.topLeft).isCloseTo(.red))
}

// MARK: - Orientation

/// All eight EXIF orientations land the marker blocks where they belong.
///
/// The fixture is asymmetric in both axes and in aspect ratio; a symmetric one
/// would pass with the transform inverted, transposed, or absent. TIFF carries
/// the orientation in a native tag and stores the raster losslessly, so a
/// failure here is the transform's fault and not the codec's.
@Test(arguments: 1...8)
func downscaleAppliesEveryExifOrientation(orientation: Int) throws {
    let storedWidth = 90, storedHeight = 60
    let source = encoded(
        markerImage(width: storedWidth, height: storedHeight),
        as: .tiff,
        orientation: orientation
    )
    let output = try ImageDownscaler.downscale(source)
    let raster = try #require(Raster(output))

    let transposes = (5...8).contains(orientation)
    #expect(raster.width == (transposes ? storedHeight : storedWidth))
    #expect(raster.height == (transposes ? storedWidth : storedHeight))

    for (storedCorner, color) in MarkerPattern.storedCorners {
        let visual = storedCorner.mapped(byOrientation: orientation)
        #expect(
            raster.corner(visual).isCloseTo(color),
            "orientation \(orientation): expected \(color) at \(visual), got \(raster.corner(visual))"
        )
    }
}

/// Orientation is applied rather than carried, because JPEG output of a
/// downscale has no EXIF left to carry it in.
@Test func downscaleWritesNoOrientationTagBecauseItAlreadyBakedItIn() throws {
    let source = encoded(markerImage(width: 90, height: 60), as: .tiff, orientation: 6)
    let output = try ImageDownscaler.downscale(source)
    let imageSource = try #require(CGImageSourceCreateWithData(output as CFData, nil))
    let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
    let tag = properties?[kCGImagePropertyOrientation] as? Int
    #expect(tag == nil || tag == 1)
}

// MARK: - Byte ceiling

@Test func downscaleKeepsOutputUnderTheByteCeiling() throws {
    let source = encoded(noiseImage(width: 1024, height: 1024, seed: 42), as: .png)
    let output = try ImageDownscaler.downscale(source)
    #expect(output.count <= ImageDownscaler.byteCeiling)
}

/// The quality ladder actually runs, rather than the ceiling being decorative.
///
/// Per-pixel noise is the worst case a JPEG encoder can be handed; at the top
/// quality it blows the ceiling, so a passing output proves a lower rung was
/// used.
@Test func downscaleDropsQualityWhenTheTopRungWouldExceedTheCeiling() throws {
    let image = noiseImage(width: 1024, height: 1024, seed: 7)
    let atTopQuality = try #require(jpegData(image, quality: ImageDownscaler.qualityLadder[0]))
    #expect(atTopQuality.count > ImageDownscaler.byteCeiling)

    let output = try ImageDownscaler.downscale(encoded(image, as: .png))
    #expect(output.count <= ImageDownscaler.byteCeiling)
    #expect(output.count < atTopQuality.count)
}

@Test func downscaleReportsAnImageItCannotFitUnderTheCeiling() throws {
    let source = encoded(noiseImage(width: 1024, height: 1024, seed: 11), as: .png)
    #expect(throws: ImageDownscaleError.self) {
        // The shipped ceiling is unreachable by any 1024px JPEG, so the
        // exhausted-ladder path is only observable through the seam.
        try ImageDownscaler.downscale(source, byteCeiling: 1024)
    }
}

@Test func downscaleProducesAJPEG() throws {
    let output = try ImageDownscaler.downscale(encoded(markerImage(width: 1500, height: 1000), as: .png))
    let source = try #require(CGImageSourceCreateWithData(output as CFData, nil))
    let type = CGImageSourceGetType(source) as String?
    #expect(type == UTType.jpeg.identifier)
}

// MARK: - Undecodable input

@Test func downscaleRejectsEmptyData() {
    #expect(throws: ImageDownscaleError.undecodable) {
        try ImageDownscaler.downscale(Data())
    }
}

@Test func downscaleRejectsRandomBytes() {
    var generator = SeededGenerator(seed: 99)
    let junk = Data((0..<4096).map { _ in UInt8.random(in: 0...255, using: &generator) })
    #expect(throws: ImageDownscaleError.undecodable) {
        try ImageDownscaler.downscale(junk)
    }
}

/// A file cut off inside its header.
///
/// ImageIO renders a JPEG truncated mid-scan and so does Pillow server-side, so
/// a half-file is not a `415` condition and is deliberately not tested as one.
/// The recoverable case is a spool file that never got past its header, which
/// is what a crashed or out-of-space write leaves behind.
@Test(arguments: [UTType.jpeg, .png, .heic])
func downscaleRejectsAFileTruncatedInsideItsHeader(type: UTType) {
    let full = encoded(markerImage(width: 1500, height: 1000), as: type)
    let truncated = Data(full.prefix(256))
    #expect(throws: ImageDownscaleError.undecodable) {
        try ImageDownscaler.downscale(truncated)
    }
}

@Test func downscaleRejectsAZeroByteFile() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, conformingTo: .jpeg)
    try Data().write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(throws: ImageDownscaleError.undecodable) {
        try ImageDownscaler.downscale(Data(contentsOf: url))
    }
}

// MARK: - Fixture drawing

/// An asymmetric marker: red at the stored top-left, green at the stored
/// top-right, blue at the stored bottom-left, black everywhere else.
///
/// Asymmetry in both axes is what makes an orientation assertion meaningful; a
/// centered or mirrored pattern passes even when the transform is wrong.
private enum MarkerPattern {
    static let storedCorners: [(Corner, RGB)] = [
        (.topLeft, .red), (.topRight, .green), (.bottomLeft, .blue),
    ]

    static func color(x: Int, y: Int, width: Int, height: Int) -> RGB {
        let blockWidth = max(1, width / 3)
        let blockHeight = max(1, height / 3)
        let left = x < blockWidth
        let right = x >= width - blockWidth
        let top = y < blockHeight
        let bottom = y >= height - blockHeight
        if top, left { return .red }
        if top, right { return .green }
        if bottom, left { return .blue }
        return .black
    }
}

private enum Corner: CaseIterable, CustomStringConvertible {
    case topLeft, topRight, bottomLeft, bottomRight

    var description: String {
        switch self {
        case .topLeft: "top-left"
        case .topRight: "top-right"
        case .bottomLeft: "bottom-left"
        case .bottomRight: "bottom-right"
        }
    }

    /// 0 means left or top, 1 means right or bottom.
    fileprivate var axes: (x: Int, y: Int) {
        switch self {
        case .topLeft: (0, 0)
        case .topRight: (1, 0)
        case .bottomLeft: (0, 1)
        case .bottomRight: (1, 1)
        }
    }

    private static func corner(x: Int, y: Int) -> Corner {
        switch (x, y) {
        case (0, 0): .topLeft
        case (1, 0): .topRight
        case (0, 1): .bottomLeft
        default: .bottomRight
        }
    }

    /// Where a stored corner ends up once the EXIF orientation is applied.
    ///
    /// Straight from the EXIF tag definitions, which state which visual edge
    /// stored row 0 and stored column 0 correspond to. Values 5 through 8
    /// transpose, which is why they also swap the output dimensions.
    func mapped(byOrientation orientation: Int) -> Corner {
        let (x, y) = axes
        switch orientation {
        case 1: return Corner.corner(x: x, y: y)
        case 2: return Corner.corner(x: 1 - x, y: y)
        case 3: return Corner.corner(x: 1 - x, y: 1 - y)
        case 4: return Corner.corner(x: x, y: 1 - y)
        case 5: return Corner.corner(x: y, y: x)
        case 6: return Corner.corner(x: 1 - y, y: x)
        case 7: return Corner.corner(x: 1 - y, y: 1 - x)
        default: return Corner.corner(x: y, y: 1 - x)
        }
    }
}

private struct RGB: Equatable, CustomStringConvertible {
    var red: Int
    var green: Int
    var blue: Int

    static let red = RGB(red: 255, green: 0, blue: 0)
    static let green = RGB(red: 0, green: 255, blue: 0)
    static let blue = RGB(red: 0, green: 0, blue: 255)
    static let black = RGB(red: 0, green: 0, blue: 0)

    var description: String { "(\(red), \(green), \(blue))" }

    /// JPEG chroma subsampling and the palette quantization GIF applies both
    /// move saturated primaries by a few dozen counts; the blocks are far
    /// enough apart that a loose tolerance still cannot confuse two of them.
    func isCloseTo(_ other: RGB, tolerance: Int = 60) -> Bool {
        abs(red - other.red) <= tolerance
            && abs(green - other.green) <= tolerance
            && abs(blue - other.blue) <= tolerance
    }
}

private func markerImage(width: Int, height: Int) -> CGImage {
    rgbImage(width: width, height: height) { x, y in
        MarkerPattern.color(x: x, y: y, width: width, height: height)
    }
}

private func noiseImage(width: Int, height: Int, seed: UInt64) -> CGImage {
    var generator = SeededGenerator(seed: seed)
    return rgbImage(width: width, height: height) { _, _ in
        RGB(
            red: Int(UInt8.random(in: 0...255, using: &generator)),
            green: Int(UInt8.random(in: 0...255, using: &generator)),
            blue: Int(UInt8.random(in: 0...255, using: &generator))
        )
    }
}

/// Builds the raster byte-by-byte instead of drawing into a `CGContext`.
///
/// A bitmap context's user space has its origin at the bottom left, so drawing
/// into one puts a "which end is up" question between the fixture and the
/// assertion. Writing the buffer directly leaves row 0 unambiguously the top.
private func rgbImage(width: Int, height: Int, color: (Int, Int) -> RGB) -> CGImage {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let offset = (y * width + x) * 4
            let rgb = color(x, y)
            pixels[offset] = UInt8(rgb.red)
            pixels[offset + 1] = UInt8(rgb.green)
            pixels[offset + 2] = UInt8(rgb.blue)
            pixels[offset + 3] = 255
        }
    }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}

private func encoded(_ image: CGImage, as type: UTType, orientation: Int? = nil) -> Data {
    let buffer = NSMutableData()
    let destination = CGImageDestinationCreateWithData(buffer, type.identifier as CFString, 1, nil)!
    var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 1.0]
    if let orientation {
        properties[kCGImagePropertyOrientation] = orientation
    }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    _ = CGImageDestinationFinalize(destination)
    return buffer as Data
}

private func jpegData(_ image: CGImage, quality: Double) -> Data? {
    let buffer = NSMutableData()
    guard
        let destination = CGImageDestinationCreateWithData(
            buffer, UTType.jpeg.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(
        destination, image,
        [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return buffer as Data
}

// MARK: - Fixture reading

private struct Raster {
    let width: Int
    let height: Int
    private let pixels: [UInt8]

    init?(_ data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let pixelWidth = image.width
        let pixelHeight = image.height
        width = pixelWidth
        height = pixelHeight
        var buffer = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: pixelWidth * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
            return true
        }
        guard ok else { return nil }
        pixels = buffer
    }

    func color(x: Int, y: Int) -> RGB {
        let offset = (y * width + x) * 4
        return RGB(red: Int(pixels[offset]), green: Int(pixels[offset + 1]), blue: Int(pixels[offset + 2]))
    }

    /// Samples the centre of the marker block that should occupy this corner.
    func corner(_ corner: Corner) -> RGB {
        let (axisX, axisY) = corner.axes
        let x = axisX == 0 ? width / 6 : width - 1 - width / 6
        let y = axisY == 0 ? height / 6 : height - 1 - height / 6
        return color(x: x, y: y)
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1 }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state ^ (state >> 31)
    }
}

/// 96 bytes of lossless WebP carrying the marker pattern at 96x64.
private let markerWebPBase64 = """
    UklGRlgAAABXRUJQVlA4TEsAAAAvX8APADdAkG3TOd5f5RoEghD5aKaPCAQh8tFMH81/IHfRkdLZ\
    AKK2bTQKozAKo3AUjsLxZ2Hdu5+I/k/AcvFwfl22xxXfh/815xsA
    """
