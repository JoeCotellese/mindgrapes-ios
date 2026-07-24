// ABOUTME: Turns arbitrary captured image bytes into the one JPEG derivative we upload.
// ABOUTME: Fits 1024px, bakes in EXIF orientation, and holds output under a byte ceiling.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Why a set of image bytes could not become an upload derivative.
///
/// Typed and recoverable rather than fatal: SPEC 6.3 maps the server's `415`
/// to a terminal queue state, and the same condition is cheaper to detect on
/// device than after a round trip.
public enum ImageDownscaleError: Error, Sendable, Equatable {
    /// ImageIO found no image in the bytes. Random data, a file truncated
    /// inside its header, or an empty spool file all land here. Terminal:
    /// retrying cannot make corrupt bytes decode.
    case undecodable

    /// The JPEG encoder refused an image ImageIO had already decoded. Not
    /// expected to be reachable; it exists so a nil `CGImageDestination` is a
    /// thrown error rather than a force unwrap in a Share Extension.
    case encodingFailed

    /// Every quality rung still exceeded the ceiling. Carries the smallest
    /// byte count reached so a bug report says how far off it was.
    case byteCeilingExceeded(byteCount: Int)
}

/// The single image transform between capture and upload.
///
/// One transform with no knobs, because the server keeps exactly one
/// derivative per image: WebP, no dimension over 1024, quality 80
/// (`extraction/images.py`). It hashes and then discards the original bytes.
/// Downscaling to 1024 on device therefore discards nothing the server would
/// have kept, while turning a ~12 MB upload into a ~150 KB one, which is what
/// makes capture over cellular and eventually from a Watch reasonable.
///
/// The photo is a visual receipt (SPEC decision 4). Everything the user
/// actually searches for is extracted on device and travels as text, so there
/// is no archival copy to preserve and no quality setting worth exposing.
///
/// Deliberately built on ImageIO and CoreGraphics rather than UIKit: the
/// package declares macOS so the suite runs on the host, and ImageIO's
/// thumbnail path resizes without ever decoding the full-size image, which
/// matters inside a Share Extension's memory budget.
public enum ImageDownscaler {
    /// Matches the server's `MAX_DIM`, so the server's own resize is a
    /// dimensional no-op (SPEC 7.2).
    public static let maxPixelDimension = 1024

    /// A client-side bound on what a single capture costs to upload.
    ///
    /// SPEC 7.2 predicts roughly 150 KB for a real photo, so this leaves
    /// generous headroom while still being 24x under the server's 12 MiB
    /// `413` threshold. Only pathological content (per-pixel noise) ever
    /// reaches it.
    public static let byteCeiling = 512 * 1024

    /// Tried in order until one fits the ceiling.
    ///
    /// The first rung is SPEC 7.2's "quality ~0.8"; the rest exist so that a
    /// dense image gives up quality rather than dimensions. Dimensions are not
    /// negotiable: dropping below 1024 would discard detail the server would
    /// have kept.
    static let qualityLadder: [Double] = [0.8, 0.6, 0.4, 0.3, 0.2]

    /// Produces the JPEG derivative to spool and upload.
    ///
    /// - Parameter data: the captured bytes, in any format SPEC 6.3 lists the
    ///   server as accepting: JPEG, PNG, WebP, GIF, HEIC/HEIF, TIFF, BMP.
    /// - Returns: JPEG bytes with no dimension over ``maxPixelDimension`` and
    ///   a length no greater than ``byteCeiling``.
    public static func downscale(_ data: Data) throws(ImageDownscaleError) -> Data {
        try downscale(data, byteCeiling: byteCeiling)
    }

    /// The ceiling is a parameter only so tests can reach the exhausted-ladder
    /// path; no shipping caller passes anything but the default.
    static func downscale(_ data: Data, byteCeiling: Int) throws(ImageDownscaleError) -> Data {
        // `kCGImageSourceShouldCache: false` keeps the decoded raster out of
        // ImageIO's cache, which matters where this runs: a Share Extension.
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(
                  data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0
        else { throw .undecodable }

        // Asking for a thumbnail no larger than the image itself makes "never
        // upscale" our guarantee rather than ImageIO's. ImageIO happens not to
        // enlarge past the source today, but that is not documented, and an
        // upscaled receipt would cost bytes for pixels nobody captured.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Applies the EXIF orientation to the pixels. It has to be applied
            // rather than carried, because the JPEG we emit has no EXIF left
            // to carry it in.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixelSize(of: source),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { throw .undecodable }

        var smallest = Int.max
        for quality in qualityLadder {
            guard let encoded = jpeg(image, quality: quality) else { throw .encodingFailed }
            if encoded.count <= byteCeiling { return encoded }
            smallest = min(smallest, encoded.count)
        }
        throw .byteCeilingExceeded(byteCount: smallest)
    }

    /// The longest side the output may have: 1024, or the source's own longest
    /// side when that is already smaller.
    ///
    /// Orientation does not enter into it. Orientations 5 through 8 transpose
    /// the image, but `max(width, height)` is unchanged by transposition.
    private static func thumbnailMaxPixelSize(of source: CGImageSource) -> Int {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let longest = max(width, height)
        // A source that will not report its dimensions still gets a bound; the
        // thumbnail call is the thing that decides whether it decodes at all.
        guard longest > 0 else { return maxPixelDimension }
        return min(longest, maxPixelDimension)
    }

    private static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            buffer, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return buffer as Data
    }
}
