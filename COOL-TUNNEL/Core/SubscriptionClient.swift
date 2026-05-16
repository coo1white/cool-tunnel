// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//
// Fetches a `SubscriptionManifestV1` from the panel's
// `GET /api/v1/subscription/<token>` endpoint over HTTPS.
//
// Trust anchor: TLS to the panel domain. The HMAC signature is
// computed with the server-only `APP_KEY` and is not client-
// verifiable. Cert validation is URLSession's default; pinning
// is deferred (would conflict with the "paste one URL" UX).
//
// The 1 MB body cap is enforced **during** the read via streaming
// `bytes(for:)` accumulation. `data(for:)` would buffer the full
// body before the cap could fire, so a hostile gigabit stream can
// land >1 GB in memory inside the 10 s timeout window.
//
// Redirects forbidden — following one silently moves the trust
// anchor. `NoRedirectGuard` cancels every redirect.

import Foundation
import os

/// Errors raised by [`SubscriptionClient`]. Translated in
/// `TunnelOrchestrator.importFromSubscriptionURL(_:)` into
/// `SubscriptionImportError` for the UI.
public enum SubscriptionClientError: LocalizedError, Sendable, Equatable {
    /// The URL string couldn't be parsed.
    case malformedURL(String)
    /// Scheme wasn't `https` — the manifest carries a cleartext
    /// password; shipping over `http` defeats the trust model.
    case nonHTTPSURL(String)
    /// Transport failure. `URLError` collapsed to a string for
    /// `Sendable + Equatable` (the SDK's `URLError` isn't
    /// `Equatable`).
    case transportFailed(String)
    /// Non-success HTTP status.
    case httpStatus(Int)
    /// Body exceeded [`SubscriptionClient.maxBytes`].
    case oversizeBody(cap: Int)
    /// `Content-Type` wasn't an `application/json` family —
    /// almost always the cover-site path. Distinct from
    /// `malformedManifest` so the UI can short-circuit without
    /// parsing multi-megabyte HTML.
    case unexpectedContentType(String)
    /// Body wasn't valid JSON or didn't match the schema —
    /// typically the cover site for a rejected token.
    case malformedManifest(String)
    /// Manifest decoded but failed validation
    /// (version / expiry / freshness).
    case manifestRejected(SubscriptionValidationError)

    public var errorDescription: String? {
        switch self {
        case .malformedURL:
            "The subscription URL could not be parsed."
        case .nonHTTPSURL(let scheme):
            "The subscription URL must start with https:// (got '\(scheme)')."
        case .transportFailed(let msg):
            "Could not reach the subscription server: \(msg)."
        case .httpStatus(let code):
            "The subscription server returned HTTP \(code)."
        case .oversizeBody(let cap):
            "The subscription response exceeded the \(cap / (1024 * 1024)) MB cap."
        case .unexpectedContentType(let media):
            "The subscription server returned content of type '\(media)' instead of JSON."
        case .malformedManifest:
            "The subscription response was not a valid manifest."
        case .manifestRejected(let validation):
            validation.errorDescription
        }
    }
}

/// Fetches and decodes [`SubscriptionManifestV1`] from a panel URL.
public actor SubscriptionClient {

    /// Per-fetch deadline. Matches the engine pre-flight defaults
    /// (5 s connect + 5 s body window) so a user comparing the two
    /// probes sees consistent timing.
    public static let defaultTimeout: TimeInterval = 10

    /// Hard cap on response body size. A real manifest is ~1 KB.
    public static let maxBytes: Int = 1024 * 1024

    private let session: URLSession
    private let decoder: JSONDecoder

    public init(
        session: URLSession? = nil,
        decoder: JSONDecoder = JSONDecoder()
    ) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            // Last-resort guard against an HTTP-aware proxy on the
            // user's network caching a 200 body without honouring
            // the panel's `Cache-Control: no-store`.
            config.urlCache = nil
            config.timeoutIntervalForRequest = Self.defaultTimeout
            config.timeoutIntervalForResource = Self.defaultTimeout
            self.session = URLSession(configuration: config)
        }
        self.decoder = decoder
    }

    /// Fetches the manifest from `urlString` and validates it
    /// against version / expiry / freshness rules. `now` is
    /// injected for testability.
    public func fetch(
        from urlString: String,
        now: Date = Date()
    ) async throws -> SubscriptionManifestV1 {
        let url = try Self.parseURL(urlString)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // No Accept header — the panel doesn't content-negotiate
        // and a custom Accept is one more fingerprint surface.

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            // Streaming read so the cap is enforced **during** the
            // fetch — see file header.
            (bytes, response) = try await session.bytes(
                for: request, delegate: NoRedirectGuard.shared
            )
        } catch {
            // `URLError.localizedDescription` frequently embeds the
            // full failing URL including the path-embedded
            // subscription token. Redact before log AND throw.
            let redacted = LifecycleTelemetryLogger.redact(error.localizedDescription)
            Self.logger.error(
                "subscription fetch transport error: \(redacted, privacy: .public)"
            )
            throw SubscriptionClientError.transportFailed(redacted)
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            // The panel's own error path is a 200 cover-site, so
            // a non-2xx means the request didn't reach the panel
            // (CDN error, proxy interposition, DNS misdirection).
            throw SubscriptionClientError.httpStatus(http.statusCode)
        }

        // Content-Type sniff — cheap cover-site short-circuit
        // before parsing potentially multi-megabyte HTML.
        if let http = response as? HTTPURLResponse,
            let raw = http.value(forHTTPHeaderField: "Content-Type")
        {
            // `value(forHTTPHeaderField:)` collapses multi-value
            // headers into a comma-joined string. Take the first
            // comma-separated token so a panel-side header bug
            // (`application/json, text/html`) doesn't surface as a
            // misleading "URL doesn't match an account" banner.
            let firstValue =
                raw.split(separator: ",").first.map(String.init) ?? raw
            let media =
                firstValue.split(separator: ";").first
                .map { String($0).trimmingCharacters(in: .whitespaces).lowercased() }
                ?? firstValue.lowercased()
            // `+json` suffix requires a `/` before it so a
            // pathological value like `evil+json` doesn't pass.
            let isJSON =
                media == "application/json"
                || (media.contains("/") && media.hasSuffix("+json"))
            if !isJSON {
                throw SubscriptionClientError.unexpectedContentType(media)
            }
        }
        // Absent Content-Type is unusual but not disqualifying —
        // the decoder will reject non-JSON bytes anyway.

        // Bound is enforced by `prefix(maxBytes + 1)`: iteration
        // terminates deterministically once that many bytes are
        // seen. Pre-allocate the full cap so per-byte appends
        // never trigger Data's geometric realloc.
        var data = Data()
        data.reserveCapacity(Self.maxBytes)
        do {
            for try await byte in bytes.prefix(Self.maxBytes + 1) {
                data.append(byte)
            }
            if data.count > Self.maxBytes {
                throw SubscriptionClientError.oversizeBody(cap: Self.maxBytes)
            }
        } catch let error as SubscriptionClientError {
            throw error
        } catch {
            // Body-read errors can wrap the URL — same redaction
            // discipline as the fetch path above.
            let redacted = LifecycleTelemetryLogger.redact(error.localizedDescription)
            Self.logger.error(
                "subscription body read error: \(redacted, privacy: .public)"
            )
            throw SubscriptionClientError.transportFailed(redacted)
        }

        let manifest: SubscriptionManifestV1
        do {
            manifest = try decoder.decode(SubscriptionManifestV1.self, from: data)
        } catch {
            // Cover-site HTML doesn't decode as the manifest
            // schema — translate to a friendlier error than the
            // JSON decoder's verbose default.
            throw SubscriptionClientError.malformedManifest(error.localizedDescription)
        }

        do {
            try manifest.validate(now: now)
        } catch let error as SubscriptionValidationError {
            throw SubscriptionClientError.manifestRejected(error)
        }

        return manifest
    }

    /// Validates and parses the user-supplied URL string. Public
    /// so the UI can pre-validate before calling `fetch`.
    public static func parseURL(_ urlString: String) throws -> URL {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            throw SubscriptionClientError.malformedURL(trimmed)
        }
        guard url.scheme?.lowercased() == "https" else {
            throw SubscriptionClientError.nonHTTPSURL(url.scheme ?? "")
        }
        // `URL(string:)` accepts hostless inputs like `https://`
        // or `https:///path`; reject before the network call so
        // the UI surfaces "malformed URL" rather than an opaque
        // transport error.
        guard let host = url.host, !host.isEmpty else {
            throw SubscriptionClientError.malformedURL(trimmed)
        }
        return url
    }

    private static let logger = Logger.cooltunnel("SubscriptionClient")
}

/// `URLSessionTaskDelegate` that refuses every HTTP redirect.
/// Following one would silently move the trust anchor; subscription
/// endpoints are served by the panel itself, so legitimate redirect
/// targets do not exist.
final class NoRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    /// `@unchecked Sendable` is sound here — no mutable state.
    static let shared = NoRedirectGuard()

    override private init() {
        super.init()
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Log host only — never the full URL. A panel that
        // incorrectly preserves the subscription token in the
        // redirect target's query string would otherwise leak it
        // through `os_log` at `privacy: .public`.
        let host = request.url?.host ?? "<unknown>"
        Logger.cooltunnel("SubscriptionClient").info(
            "subscription redirect refused (target host: \(host, privacy: .public))"
        )
        completionHandler(nil)
    }
}
