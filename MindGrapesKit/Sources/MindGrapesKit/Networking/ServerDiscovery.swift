// ABOUTME: Turns the URL a user types during onboarding into a base URL and probes it for reachability.
// ABOUTME: Normalization is pure; the probe reuses BrainClient.checkHealth() and its error classifier.

import Foundation

/// Discovery is the step between a string the user typed and a `ServerConfig`
/// the rest of the app can trust (SPEC 6.1, Decision 6). It is a separate
/// concern from `ServerConfig` on purpose: that type stores a verified base URL
/// and says nothing about how a raw string became one.
///
/// Item #9 brought the thin subset Slice 1 needed: manual URL entry plus the
/// `/healthz` probe. Slice 7 (#20) added ``baseURL(fromScannedCode:)`` for the
/// QR the server renders on `/connect`.
public enum ServerDiscovery {
    /// What the `/healthz` probe learned about a typed URL. Three states because
    /// the connect screen has to tell the user *which* thing is wrong: the URL
    /// (`wrongHost`) or the connection (`unreachable`).
    public enum Reachability: Sendable, Equatable {
        /// A Mind Grapes `/healthz` answered `ok`.
        case reachable
        /// Something answered, but it is not a healthy Mind Grapes probe: a
        /// captive portal, an unrelated site, a `4xx`. The URL is the thing to
        /// fix.
        case wrongHost
        /// Nothing answered, or the server is having a bad minute (a transport
        /// failure or a `5xx`). Says nothing about whether the URL is right.
        case unreachable
    }

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

    /// The base `URL` a scanned QR carries, or `nil` when the symbol is not one
    /// of ours.
    ///
    /// Stricter than ``normalizedURL(from:)`` on purpose: the scheme must be
    /// spelled out. A human typing `grapes.example.ts.net` means a host and
    /// deserves the `https` default, but a scanned symbol is machine-written,
    /// and the server always encodes a full URL. Without that rule a Wi-Fi
    /// symbol or a printed word parses as a plausible host, and the user gets a
    /// connection error for what is really "that is not a Mind Grapes code".
    ///
    /// The scan carries a hostname and nothing else: no token, no pairing
    /// secret, no short-lived code. It grants no access on its own, and the
    /// passkey ceremony still runs afterward. Keep it that way.
    public static func baseURL(fromScannedCode payload: String) -> URL? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return nil }
        return normalizedURL(from: trimmed)
    }
}

extension BrainClient {
    /// The `/healthz` probe reduced to a single value for the connect screen.
    ///
    /// `checkHealth()` already does the real work (no bearer, body must read
    /// `ok`); this only classifies its outcome without throwing, so a Check
    /// button can render a result directly.
    ///
    /// One known limitation: a transient `4xx` such as `429` or `408` reads as
    /// `wrongHost` rather than `unreachable`, because the classification keys off
    /// `5xx`-vs-not (`BrainClientError.retryDisposition`). Neither is expected on
    /// an unauthenticated `/healthz`, so the thin slice does not special-case
    /// them; revisit there if a real deployment rate-limits the probe.
    public func probeReachability() async -> ServerDiscovery.Reachability {
        do {
            try await checkHealth()
            return .reachable
        } catch let error as BrainClientError {
            // Reuse the retry classifier rather than re-switch on status. A
            // retryable failure is a transport error or a 5xx: the server, not
            // the URL, so `unreachable`. Everything else is a live server giving
            // a non-`ok` answer (captive portal, 4xx, 200-not-`ok`), so the URL
            // is suspect: `wrongHost`.
            return error.retryDisposition == .retry ? .unreachable : .wrongHost
        } catch {
            // checkHealth() only ever throws BrainClientError; this arm is here
            // for exhaustiveness and treats an unknown error as a bad answer.
            return .wrongHost
        }
    }
}
