// Core/SubscriptionClient.swift
//
// Fetches a `SubscriptionManifestV1` from the panel's
// `GET /api/v1/subscription/<token>` endpoint over HTTPS.
//
// Design notes:
//
// * Trust anchor is TLS — the panel's HMAC signature is computed
//   with the server-only `APP_KEY` and cannot be verified
//   client-side. We let `URLSession` do system-default cert
//   validation; pinning is left to a future revision (would require
//   the user to paste a fingerprint at setup time, which contradicts
//   the "paste one URL" UX of the subscription flow).
// * Anti-fingerprint cover-site means error paths return HTTP 200
//   with `text/html`, identical to a vanilla unknown-path probe. We
//   distinguish "subscription endpoint exists" from "cover-site"
//   purely by JSON-decoding the body; a `Content-Type` check rules
//   out the easy cover-site case before we waste a parse on
//   multi-megabyte HTML.
// * No caching. The panel sets `Cache-Control: no-store`; we mirror
//   the intent by giving every request a fresh `URLSession`
//   configuration with `requestCachePolicy = .reloadIgnoringLocalCacheData`.
// * Per-fetch deadline: 10 seconds. Long enough that a trans-
//   continental panel + slow client connection completes; short
//   enough that a stuck network surfaces an error before the user
//   notices the spinner.

import Foundation
import os

/// Errors raised by [`SubscriptionClient`].
public enum SubscriptionClientError: Error, Sendable, Equatable {
    /// The URL string couldn't be parsed.
    case malformedURL(String)
    /// The URL scheme wasn't `https`. We refuse plaintext
    /// subscriptions outright — the manifest carries a cleartext
    /// password, and shipping it over `http` would defeat the
    /// entire trust model.
    case nonHTTPSURL(String)
    /// `URLSession` reported a transport failure (DNS, TLS,
    /// connection reset, etc.). The wrapped error is a
    /// `URLError`; surfaced as a string for `Sendable + Equatable`
    /// conformance (the SDK's `URLError` isn't `Equatable`).
    case transportFailed(String)
    /// The HTTP response carried a non-success status. Includes
    /// the status code so the UI can surface the panel's intent
    /// (4xx = bad token, 5xx = panel is sick).
    case httpStatus(Int)
    /// The body wasn't valid JSON or didn't match the
    /// [`SubscriptionManifestV1`] schema. Almost always means the
    /// panel served the cover site (HTTP 200, `text/html`) because
    /// the token was rejected upstream of the endpoint.
    case malformedManifest(String)
    /// The manifest decoded but failed validation
    /// (version/expiry/freshness). Surfaces the underlying reason.
    case manifestRejected(SubscriptionValidationError)
}

/// Fetches and decodes [`SubscriptionManifestV1`] from a panel URL.
///
/// `actor` rather than `struct` so the `URLSession` instance is
/// owned by exactly one isolation context — which `URLSession`
/// itself is happy with (it's documented thread-safe), but the
/// pattern matches the rest of the Swift surface (`CoreClient` is
/// also an actor).
public actor SubscriptionClient {

    /// Per-fetch deadline. Picked to match the existing engine
    /// pre-flight defaults (5 s connect + a 5 s body window) so a
    /// user comparing the two probes against the same panel sees
    /// consistent timing.
    public static let defaultTimeout: TimeInterval = 10

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
            // The panel itself sets `Cache-Control: no-store`, but
            // a misbehaving HTTP-aware proxy on the user's network
            // could still cache without that header on a 200 body.
            // Disabling URLSession's local cache here gives one
            // last belt-and-braces guarantee that the manifest the
            // user sees is the manifest the panel emitted.
            config.urlCache = nil
            config.timeoutIntervalForRequest = Self.defaultTimeout
            config.timeoutIntervalForResource = Self.defaultTimeout
            self.session = URLSession(configuration: config)
        }
        self.decoder = decoder
    }

    /// Fetches the manifest from `urlString` and validates it
    /// against version / expiry / freshness rules.
    ///
    /// `now` is injected so tests don't depend on wall-clock time;
    /// production callers omit it.
    public func fetch(
        from urlString: String,
        now: Date = Date()
    ) async throws -> SubscriptionManifestV1 {
        let url = try Self.parseURL(urlString)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // Match the panel's no-store policy on the way in too.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // No Accept header — the panel doesn't content-negotiate
        // and a custom Accept is one more fingerprint surface.

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // `URLError` doesn't conform to `Equatable`, so collapse
            // to its `localizedDescription` for our error type's
            // `Equatable` impl. The full underlying error is
            // already in the system log via `URLSession` itself;
            // we don't double-log here.
            Self.logger.error(
                "subscription fetch transport error: \(error.localizedDescription, privacy: .public)"
            )
            throw SubscriptionClientError.transportFailed(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            // Panel-controlled error path is a 200 cover-site, so
            // any non-2xx here means the request didn't reach the
            // panel at all — a CDN error, a proxy interposition,
            // or DNS misdirection. Surface the status straight to
            // the UI so the user can debug.
            throw SubscriptionClientError.httpStatus(http.statusCode)
        }

        let manifest: SubscriptionManifestV1
        do {
            manifest = try decoder.decode(SubscriptionManifestV1.self, from: data)
        } catch {
            // The panel returns the cover site for every error
            // path (bad token, expired, rate-limited). HTML
            // doesn't decode as the manifest schema, which is
            // exactly what we land on here. Translate to a
            // friendlier error than the JSON decoder's
            // verbose default.
            throw SubscriptionClientError.malformedManifest(error.localizedDescription)
        }

        do {
            try manifest.validate(now: now)
        } catch let error as SubscriptionValidationError {
            throw SubscriptionClientError.manifestRejected(error)
        }
        // `validate` only throws `SubscriptionValidationError`, so
        // the catch above is exhaustive in practice. Compiler
        // doesn't know that without a `try!` (which the project
        // bans) so we re-throw any other error untouched.

        return manifest
    }

    /// Validates and parses the user-supplied URL string.
    /// Refuses anything that isn't `https://`. Public so the UI
    /// can pre-validate before calling `fetch` (e.g. enable a
    /// "Fetch" button only when the URL parses).
    public static func parseURL(_ urlString: String) throws -> URL {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            throw SubscriptionClientError.malformedURL(trimmed)
        }
        // Some panels run on a non-default HTTPS port (operator
        // chose `:8443` to avoid a Caddy port collision with the
        // sing-box `:443` listener). The scheme is the only thing
        // we strictly enforce.
        guard url.scheme?.lowercased() == "https" else {
            throw SubscriptionClientError.nonHTTPSURL(url.scheme ?? "")
        }
        return url
    }

    private static let logger = Logger.cooltunnel("SubscriptionClient")
}
