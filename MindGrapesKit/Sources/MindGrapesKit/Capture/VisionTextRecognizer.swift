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
            // Vision can BOTH call the request completion with an error AND rethrow
            // from perform on the same failure. A naive double-resume traps the
            // continuation, so guard it: resume exactly once, whichever path fires
            // first. This is what keeps the seam's "OCR never fails a capture"
            // contract from turning into a crash.
            let resumeOnce = ResumeOnce(continuation)

            // OCR is CPU-heavy and synchronous; run it off the cooperative thread
            // pool so it does not starve other tasks. The request and handler are
            // built inside the closure so no non-Sendable Vision object crosses the
            // dispatch boundary.
            DispatchQueue.global(qos: .utility).async {
                let request = VNRecognizeTextRequest { request, error in
                    guard error == nil,
                          let observations = request.results as? [VNRecognizedTextObservation]
                    else {
                        resumeOnce.resume(with: "")
                        return
                    }
                    let text = observations
                        .compactMap { $0.topCandidates(1).first?.string }
                        .joined(separator: "\n")
                    resumeOnce.resume(with: text)
                }
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true

                let handler = VNImageRequestHandler(data: imageData, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    resumeOnce.resume(with: "")
                }
            }
        }
    }
}

/// Resumes a `String`/`Never` continuation at most once, so the Vision
/// double-signal (completion error + perform throw) cannot trap it.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Never>?

    init(_ continuation: CheckedContinuation<String, Never>) {
        self.continuation = continuation
    }

    func resume(with value: String) {
        let continuation = lock.withLock { () -> CheckedContinuation<String, Never>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: value)
    }
}
#endif
