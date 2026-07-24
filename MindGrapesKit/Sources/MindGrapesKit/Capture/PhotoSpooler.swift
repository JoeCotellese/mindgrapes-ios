// ABOUTME: Downscales captured image bytes and writes the one JPEG derivative to the App Group spool.
// ABOUTME: Returns the filename a CaptureRecord names; the bytes never enter the database (SPEC 8.1).

import Foundation

/// The bridge from raw captured bytes to a spooled, named derivative.
///
/// One step: ``ImageDownscaler`` shrinks the bytes to the single upload
/// derivative (SPEC 7.2), then they are written into the App Group photo spool
/// under a fresh name. The caller puts that name on a ``PhotoDraft`` /
/// ``CaptureRecord``; the queue reads the file back at drain time.
///
/// ponytail: no dedup, no cleanup of orphaned spool files here. A capture that
/// never enqueues leaves a stray file; ``CaptureQueue`` deletes on success and
/// prune. Add sweep-on-launch only if orphans are ever observed to matter.
public enum PhotoSpooler {
    /// Downscales `imageData` and writes it to the spool, returning the filename.
    ///
    /// - Parameters:
    ///   - imageData: the captured bytes, in any format SPEC 6.3 accepts.
    ///   - appGroup: the container whose photo spool receives the file.
    ///   - id: names the file. Defaulted; a caller aligning the spool name with a
    ///     capture id may pass one.
    /// - Throws: ``ImageDownscaleError`` for bytes that will not decode or fit
    ///   (terminal: a caller rejects the capture), or a file-system error if the
    ///   write fails.
    @discardableResult
    public static func spool(
        _ imageData: Data,
        into appGroup: AppGroupContainer,
        id: UUID = UUID()
    ) throws -> String {
        let derivative = try ImageDownscaler.downscale(imageData)
        try appGroup.prepareDirectories()
        let filename = "\(id.uuidString).jpg"
        try derivative.write(to: appGroup.photoSpoolFileURL(named: filename), options: .atomic)
        return filename
    }
}
