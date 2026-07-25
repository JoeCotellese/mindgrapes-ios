// ABOUTME: The on-device description seam (item 13): OCR + context -> a standalone statement.
// ABOUTME: Behind a protocol with an availability gate so the template fallback covers no-Apple-Intelligence.

import Foundation

/// Generates a photo's description from its OCR text and context (SPEC 7.2, 7.3).
///
/// The dog-food-label use case: on a device with Apple Intelligence, the
/// on-device model turns "PURINA ONE ... SALMON" plus the timestamp into a
/// sentence a human can read later. ``isAvailable`` gates the call so a device
/// without the model never invokes generation and falls straight to the template.
///
/// A seam so the pipeline tests against a fake; the real Foundation Models
/// implementation is nondeterministic and device-verified, never unit-tested.
public protocol DescriptionGenerating: Sendable {
    /// Whether the on-device model can run right now (Apple Intelligence enabled,
    /// model present). When `false` the pipeline uses the template and never calls
    /// ``generateDescription(ocrText:occurredAt:timeZone:)``.
    var isAvailable: Bool { get }

    /// Composes a standalone description. Throws on model failure; the pipeline
    /// treats a throw the same as unavailable and uses the template fallback, so a
    /// capture never hard-fails for the model's sake (SPEC 7.3).
    func generateDescription(ocrText: String, occurredAt: Date, timeZone: TimeZone) async throws -> String
}

/// The default generator: never available, so the pipeline always uses the
/// template. Stands in until a real generator is injected and on any build
/// without Foundation Models.
public struct TemplateOnlyDescriptionGenerator: DescriptionGenerating {
    public init() {}
    public var isAvailable: Bool { false }
    public func generateDescription(ocrText: String, occurredAt: Date, timeZone: TimeZone) async throws -> String {
        // Never reached: the pipeline checks isAvailable first. Present only to
        // satisfy the protocol.
        throw DescriptionGenerationError.unavailable
    }
}

public enum DescriptionGenerationError: Error, Sendable, Equatable {
    /// The on-device model is not usable on this device.
    case unavailable
}
