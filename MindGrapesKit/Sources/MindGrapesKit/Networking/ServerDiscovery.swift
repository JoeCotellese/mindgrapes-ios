// ABOUTME: Turns the URL a user types during onboarding into a base URL and probes it for reachability.
// ABOUTME: Normalization is pure; the probe reuses BrainClient.checkHealth() and its error classifier.

import Foundation

/// Discovery is the step between a string the user typed and a `ServerConfig`
/// the rest of the app can trust (SPEC 6.1, Decision 6). It is a separate
/// concern from `ServerConfig` on purpose: that type stores a verified base URL
/// and says nothing about how a raw string became one.
///
/// This is the thin subset item #9 needs for Slice 1: manual URL entry plus the
/// `/healthz` probe. QR parsing is Slice 7.
public enum ServerDiscovery {
    /// Normalizes what the user typed into a base `URL`, or `nil` when the input
    /// cannot be one.
    ///
    /// - Surrounding whitespace is trimmed; empty input is `nil`.
    /// - A bare host (or `host:port`, or `host/path`) defaults to `https`.
    /// - A non-`http(s)` scheme (`ftp://`, `file://`, …) is rejected: it is not
    ///   something the client can probe or capture over.
    /// - Any path is preserved, so a reverse-proxy subpath survives. A trailing
    ///   slash is left as typed because `BrainClient` appends its endpoints and
    ///   is slash-agnostic (see `BrainClient.endpoint(_:)`).
    public static func normalizedURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let withScheme: String
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            withScheme = trimmed
        } else if trimmed.contains("://") {
            // ponytail: any other scheme is unusable for an HTTP probe. Reject
            // rather than coerce, so a mistyped "ftp://" surfaces as invalid.
            return nil
        } else {
            // ponytail: key the "has a scheme" test off "://", not RFC 3986.
            // RFC would read "example.com" in "example.com:8080" as a scheme;
            // the user means host and port, so default the scheme to https.
            withScheme = "https://" + trimmed
        }

        guard let components = URLComponents(string: withScheme),
              let host = components.host, !host.isEmpty
        else { return nil }
        return components.url
    }
}
