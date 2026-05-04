// SystemIntegration/GitHubTrust.swift
//
// Shared trust boundary for the three Cool Tunnel updaters that
// pull from GitHub releases:
//
//   - AppUpdater         → coo1white/cool-tunnel (the .app itself)
//   - NaiveUpdater       → klzgrad/naiveproxy     (the bundled `naive`)
//   - RustCoreUpdater    → coo1white/cool-tunnel  (the engine binary)
//
// Without these helpers, each updater previously relied on
// `URLSession.shared` defaults — which follow up to ~20 redirects
// to any host with no validation. SHA-256 manifest pinning (where
// it exists, currently only on AppUpdater) protects the *content*
// of the .zip but anchors trust in the manifest URL — and the
// manifest URL itself was being followed through unrestricted
// redirects until v0.1.7.11.
//
// What this module provides:
//
//   - `isTrustedGitHubURL(_:)`: HTTPS + host-suffix check.
//     Acceptable hosts: `*.github.com`, `*.githubusercontent.com`,
//     and the bare suffixes themselves. Used at the JSON-decode
//     seam (validate `browser_download_url` before any download)
//     and inside `GitHubRedirectGuard` for any HTTP redirect.
//
//   - `GitHubRedirectGuard.shared`: a stateless singleton
//     `URLSessionTaskDelegate` that constrains redirect targets
//     to the same host-suffix list. Pass to
//     `URLSession.shared.data(for:delegate:)` /
//     `URLSession.shared.download(for:delegate:)` (per-task
//     delegate, macOS 12+).
//
//   - `GitHubRedirectGuard.download(url:to:)`: full
//     host-validated, redirect-guarded download into a per-pipeline
//     `tempRoot`. NaiveUpdater + RustCoreUpdater share the
//     primitive; AppUpdater stays bespoke because it adds a
//     per-asset size cap (.sha256 1 MB / .zip 100 MB) that the
//     other two don't need.

import Foundation
import os

extension Logger {
    /// **R-F#1:** project-wide Logger factory. Three sites
    /// previously spelled out
    /// `Logger(subsystem: "space.coolwhite.cooltunnel", category: ...)`
    /// — `CoreClient.logger`, `AppUpdater.appUpdaterLogger`, and
    /// `GitHubTrust.trustLogger` — each carrying the subsystem
    /// string as a literal. The orphan-subsystem regression that
    /// R-F#2 just fixed (the legacy `"com.cool-tunnel.app"`
    /// string) becomes structurally impossible when there's only
    /// one place that knows the subsystem identifier.
    static func cooltunnel(_ category: String) -> Logger {
        Logger(subsystem: "space.coolwhite.cooltunnel", category: category)
    }
}

/// Thrown by `GitHubRedirectGuard.download` when the supplied
/// URL fails `isTrustedGitHubURL`. Distinct from generic
/// `URLError` so callers can pattern-match on the trust-boundary
/// reject specifically.
struct UntrustedGitHubHostError: Error, Sendable {
    let url: URL
}

/// Hosts we trust to serve GitHub release assets. Matched as
/// case-insensitive suffixes (entry equals host, OR host ends in
/// `"." + entry`). Keep this list short and explicit — every
/// addition expands the trust boundary.
private let trustedHostSuffixes: [String] = [
    "github.com",
    "githubusercontent.com",
]

/// Returns true if `url` is HTTPS and its host is on the trusted
/// GitHub-served suffix list.
///
/// The HTTPS check is non-negotiable: a release URL that
/// downgrades to `http://` or any non-https scheme is rejected
/// outright. This defends against an upstream API response that
/// opts users into plaintext (TLS-strip / downgrade attacks).
///
/// **E-F#3 (v0.1.7.14):** dropped the `.lowercased()` calls on
/// `url.scheme` and `url.host`. Both are already canonicalised
/// to lowercase by Foundation per RFC 3986 §3.1 (scheme) and
/// §3.2.2 (host); the explicit lowercase was wasted allocation.
func isTrustedGitHubURL(_ url: URL) -> Bool {
    guard url.scheme == "https" else { return false }
    guard let host = url.host else { return false }
    return trustedHostSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
}

/// `URLSessionTaskDelegate` that constrains HTTP redirects to the
/// trusted GitHub-served host suffix list, AND a static
/// `download(url:to:)` helper that does the full host-validated +
/// redirect-guarded download.
///
/// Why the redirect guard matters: SHA pinning protects the
/// .zip's *content* but TRUSTS the manifest URL. A CDN takeover,
/// misconfigured GitHub edge redirect, or attacker-shaped API
/// response that pointed the manifest fetch at a non-GitHub host
/// would defeat SHA pinning by substituting the verification
/// root-of-trust.
///
/// NaiveUpdater + RustCoreUpdater don't currently SHA-pin
/// (deferred to v0.2.0 per `AppUpdater.swift` Sw#C4 comment) but
/// they STILL need the redirect guard — without it, a CDN
/// takeover for `objects.githubusercontent.com` could substitute
/// the binary entirely, with the user-visible URL unchanged.
///
/// Class is `final` and stateless; `GitHubRedirectGuard.shared`
/// is a singleton servicing every URLSession task across all
/// three updaters.
final class GitHubRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    /// Shared singleton. The `@unchecked` is required by
    /// `NSObject` ancestor (which is not itself `Sendable`); it
    /// is safe here because there is no mutable state.
    static let shared = GitHubRedirectGuard()

    /// Private init so callers can't accidentally create a
    /// per-task instance.
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
        if let url = request.url, isTrustedGitHubURL(url) {
            completionHandler(request)
        } else {
            Logger.cooltunnel("GitHubTrust").info(
                "redirect rejected: \(request.url?.absoluteString ?? "<nil>", privacy: .public)"
            )
            completionHandler(nil)
        }
    }

    /// **R-F#2 (v0.1.7.14):** shared host-validated, redirect-
    /// guarded download. Replaces the line-for-line-twin
    /// `download(url:to:)` methods that NaiveUpdater and
    /// RustCoreUpdater carried. AppUpdater keeps its own
    /// inline because it layers a per-asset size cap that
    /// these callers don't need.
    ///
    /// Validates `url` against `isTrustedGitHubURL`, builds a
    /// URLRequest, downloads via the shared redirect guard,
    /// asserts HTTP 200, and moves the temp file into
    /// `destination`. `destination` is assumed to live in a
    /// per-pipeline `tempRoot` (each call site pre-creates a
    /// fresh `mkdtemp`-style directory) — the move is
    /// unconditional, no `fileExists`/`removeItem` pre-check
    /// (E-F#6 anti-pattern eliminated here too).
    ///
    /// Throws `UntrustedGitHubHostError` if the host check
    /// fails; otherwise propagates `URLSession`/`FileManager`
    /// errors to the caller for them to wrap in their own
    /// updater error type.
    static func download(url: URL, to destination: URL) async throws -> URL {
        guard isTrustedGitHubURL(url) else {
            throw UntrustedGitHubHostError(url: url)
        }
        let request = URLRequest(url: url)
        let (tempURL, response) = try await URLSession.shared.download(
            for: request, delegate: GitHubRedirectGuard.shared
        )
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(
                .badServerResponse,
                userInfo: [
                    NSURLErrorFailingURLErrorKey: url,
                    "statusCode": (response as? HTTPURLResponse)?.statusCode ?? -1,
                ]
            )
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
        return destination
    }
}
