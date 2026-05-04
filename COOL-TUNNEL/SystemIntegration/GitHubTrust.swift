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
// redirects until v0.1.7.11. v0.1.7.13 (R-F#4) extracts the
// AppUpdater-only fix into this shared module so the sibling
// updaters get the same trust boundary for free.
//
// What this module provides:
//
//   - `isTrustedGitHubURL(_:)`: HTTPS + host-suffix check.
//     Acceptable hosts: `*.github.com`, `*.githubusercontent.com`,
//     and the bare suffixes themselves. Used at TWO seams:
//     1. After decoding `browser_download_url` JSON, before
//        passing it to `URLSession.download`. (AU-2 / R-F#4.)
//     2. Inside `GitHubRedirectGuard` for any HTTP redirect
//        encountered mid-flight. (AU-3 / R-F#4.)
//
//   - `GitHubRedirectGuard`: a `URLSessionTaskDelegate` that
//     constrains redirect targets to the same host-suffix list.
//     Pass to `URLSession.shared.data(for:delegate:)` /
//     `URLSession.shared.download(for:delegate:)` (per-task
//     delegate, macOS 12+).
//
// A single `Sendable` instance is shared across all callers — the
// class has zero stored properties, so re-allocating per request
// (which the code did before E-F#3) was wasted work.

import Foundation
import os

/// Shared logger for cross-updater trust events. Subsystem
/// matches the project-wide `space.coolwhite.cooltunnel` used by
/// `CoreClient`; category is dedicated so support filtering via
/// `log show --predicate 'category == "GitHubTrust"'` surfaces
/// only the trust-boundary trace and not the per-updater chatter.
private let trustLogger = Logger(
    subsystem: "space.coolwhite.cooltunnel",
    category: "GitHubTrust"
)

/// Hosts we trust to serve GitHub release assets. Matched as
/// case-insensitive suffixes (entry equals host, OR host ends in
/// `"." + entry`). Keep this list short and explicit — every
/// addition expands the trust boundary.
///
/// `static let` so the literal allocates once at first use and
/// every call site shares the storage. (E-F#3 fix — the prior
/// AppUpdater-internal copy was a function-local `let suffixes
/// = [...]` that re-allocated on every redirect callback and
/// every asset URL validation.)
private let trustedHostSuffixes: [String] = [
    "github.com",
    "githubusercontent.com",
]

/// Returns true if `url` is HTTPS and its host is on the trusted
/// GitHub-served suffix list. Used by all three updaters before
/// handing a URL to `URLSession.download`, AND inside
/// `GitHubRedirectGuard` for mid-flight redirect decisions.
///
/// The HTTPS check is non-negotiable: a release URL that
/// downgrades to `http://` or any non-https scheme is rejected
/// outright, regardless of host. This defends against an upstream
/// API response that opts users into plaintext (TLS-strip /
/// downgrade attacks).
func isTrustedGitHubURL(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "https" else { return false }
    guard let host = url.host?.lowercased() else { return false }
    return trustedHostSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
}

/// `URLSessionTaskDelegate` that constrains HTTP redirects to the
/// trusted GitHub-served host suffix list.
///
/// Why this matters: SHA pinning protects the .zip's *content*
/// but TRUSTS the manifest URL (which defines the expected
/// hash). A CDN takeover, misconfigured GitHub edge redirect,
/// or attacker-shaped API response that pointed the manifest
/// fetch at a non-GitHub host would defeat SHA pinning by
/// substituting the verification root-of-trust. This delegate
/// rejects any redirect whose target isn't on the trusted list.
///
/// NaiveUpdater + RustCoreUpdater don't currently SHA-pin
/// (deferred to v0.2.0 per `AppUpdater.swift` Sw#C4 comment) but
/// they STILL need the redirect guard — without it, a CDN
/// takeover for `objects.githubusercontent.com` could substitute
/// the binary entirely, with the user-visible URL unchanged.
///
/// Class is `final` and stateless; a single shared instance
/// (`GitHubRedirectGuard.shared`) services every URLSession task
/// across all three updaters.
final class GitHubRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    /// Shared singleton. Stateless `final` class with no stored
    /// properties — sharing is sound and avoids the per-request
    /// allocation E-F#3 flagged. The `@unchecked` is required by
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
            // Reject the redirect. URLSession surfaces this as
            // the response that *would have been* the redirect
            // (the 3xx) — the caller's status check (we want
            // 200) catches it.
            trustLogger.info(
                "redirect rejected: \(request.url?.absoluteString ?? "<nil>", privacy: .public)"
            )
            completionHandler(nil)
        }
    }
}
