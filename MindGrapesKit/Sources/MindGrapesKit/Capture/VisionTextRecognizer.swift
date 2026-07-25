// ABOUTME: The Vision-backed OCR implementation of TextRecognizing (item 12), simulator/device-verified.
// ABOUTME: Best-effort by contract: any recognition failure resolves to "" so OCR never fails a capture.

#if canImport(Vision)
import Foundation
import Vision

/// Recognizes text with Vision.
///
/// Uses `VNRecognizeTextRequest` at the accurate level with language correction —
/// the stable OCR path that compiles across iOS and the simulator. SPEC 7.2 names
/// `RecognizeDocumentsRequest` (iOS 26's structured-document API) as the eventual
/// upgrade for layout-aware extraction; the acceptance is only that known strings
/// appear, which this satisfies. Swap to the documents request when structure
/// (columns, tables) starts to matter.
///
/// Not unit-tested: it is exercised on the simulator against reference images
/// (item 12 acceptance), asserting known strings appear rather than exact output.
public struct VisionTextRecognizer: TextRecognizing {
    public init() {}

    public func recognizeText(in imageData: Data) async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            let request = VNRecognizeTextRequest { request, error in
                guard error == nil,
                      let observations = request.results as? [VNRecognizedTextObservation]
                else {
                    continuation.resume(returning: "")
                    return
                }
                let text = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                continuation.resume(returning: text)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            // `perform` either invokes the completion (success) or throws without
            // invoking it (failure), so exactly one resume happens on each path.
            let handler = VNImageRequestHandler(data: imageData, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: "")
            }
        }
    }
}
#endif
