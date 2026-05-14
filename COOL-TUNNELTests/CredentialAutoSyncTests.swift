// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
// COOL-TUNNELTests/CredentialAutoSyncTests.swift
//
// Regression coverage for the post-v2.0.48 auth-failure auto-sync
// pipeline. The flow has three independently-testable pieces:
//
//   1. `Profile.subscriptionURL` round-trips through Codable so
//      the panel URL survives a save/reload cycle.
//   2. `TunnelOrchestrator.isProxyAuthFailureLine(_:)` correctly
//      classifies the engine stderr lines that should trigger
//      auto-sync — and ignores ones that shouldn't.
//   3. `TunnelOrchestrator.importFromSubscriptionURL(_:)` stores
//      the URL on the imported Profile (covered by the
//      orchestrator-level integration tests; this file pins the
//      Profile-level shape).
//
// The end-to-end auto-sync restart (stopQuiet + re-import +
// start) needs the SubscriptionClient + CoreClient harness and
// is exercised through TunnelOrchestratorTests.

import XCTest

@testable import Cool_Tunnel

final class CredentialAutoSyncTests: XCTestCase {

    // MARK: - Profile.subscriptionURL Codable

    func testProfileSubscriptionURLRoundTripsThroughJSON() throws {
        let original = Profile(
            id: "test",
            server: "naive.example.com",
            username: "alice",
            password: "test-password-do-not-use",
            localPort: "1080",
            subscriptionURL: "https://panel.example.com/api/v1/subscription/abc123"
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Profile.self, from: encoded)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(
            decoded.subscriptionURL,
            "https://panel.example.com/api/v1/subscription/abc123"
        )
    }

    /// Profiles persisted before v2.0.49 don't carry the
    /// `subscriptionURL` field. The Codable decoder must accept
    /// those legacy blobs and assign `nil`, otherwise the first
    /// app launch after upgrading wipes the user's profile list
    /// with a JSON-decode failure.
    func testProfileDecodesLegacyJSONWithoutSubscriptionURL() throws {
        let legacyJSON = """
            {
              "id": "default",
              "server": "naive.example.com",
              "username": "alice",
              "password": "test-password-do-not-use",
              "localPort": "1080"
            }
            """
        let data = Data(legacyJSON.utf8)
        let decoded = try JSONDecoder().decode(Profile.self, from: data)
        XCTAssertEqual(decoded.id, "default")
        XCTAssertNil(decoded.subscriptionURL)
    }

    /// The default-init parameter places `subscriptionURL: nil`
    /// at the end, so existing call sites that constructed
    /// Profiles via the five-argument signature compile
    /// unchanged.
    func testProfileDefaultStillHasNoSubscriptionURL() {
        XCTAssertNil(Profile.default.subscriptionURL)
    }

    // MARK: - isProxyAuthFailureLine — positive cases

    /// Chromium-style `ERR_PROXY_AUTH_REQUESTED` is the canonical
    /// signal NaiveProxy emits when upstream returns 407.
    func testDetectsErrProxyAuthRequested() {
        XCTAssertTrue(
            TunnelOrchestrator.isProxyAuthFailureLine(
                "[ERROR] Failed CONNECT: net::ERR_PROXY_AUTH_REQUESTED"
            ))
    }

    /// Tunnel-class auth chip — surfaces when the proxy is
    /// reachable but every CONNECT through it is rejected.
    func testDetectsErrTunnelAuth() {
        XCTAssertTrue(
            TunnelOrchestrator.isProxyAuthFailureLine(
                "net::ERR_TUNNEL_AUTH_FAILURE"
            ))
    }

    /// Plain "407 Proxy Authentication Required" appears in some
    /// proxy logs as a verbatim HTTP/1.1 status line.
    func testDetects407ProxyAuthenticationStatus() {
        XCTAssertTrue(
            TunnelOrchestrator.isProxyAuthFailureLine(
                "Received status 407 Proxy Authentication Required from upstream"
            ))
    }

    /// "Authentication required" alone — defensive catch for
    /// edge-case log shapes that don't include the status number.
    func testDetectsBareAuthenticationRequired() {
        XCTAssertTrue(
            TunnelOrchestrator.isProxyAuthFailureLine(
                "upstream rejected: authentication required"
            ))
    }

    /// Raw `407` with separator-surrounded boundary fires the
    /// auto-sync. The boundary class includes the space, period,
    /// colon, comma, and bracket families.
    func testDetectsRaw407StatusCodeWithSeparators() {
        XCTAssertTrue(
            TunnelOrchestrator.isProxyAuthFailureLine("HTTP 407 from proxy"))
        XCTAssertTrue(
            TunnelOrchestrator.isProxyAuthFailureLine("status: 407, retrying"))
        XCTAssertTrue(
            TunnelOrchestrator.isProxyAuthFailureLine("[407] auth failed"))
        XCTAssertTrue(
            TunnelOrchestrator.isProxyAuthFailureLine("/proxy/407"))
    }

    /// Case-insensitive — the matcher upper-cases the whole line
    /// for the chip patterns and uses a separator-bounded scan
    /// for the bare 407.
    func testDetectsCaseInsensitiveVariants() {
        XCTAssertTrue(
            TunnelOrchestrator.isProxyAuthFailureLine(
                "err_proxy_auth_requested"))
        XCTAssertTrue(
            TunnelOrchestrator.isProxyAuthFailureLine(
                "Proxy Authentication Required"))
    }

    // MARK: - isProxyAuthFailureLine — negative cases

    /// Normal connection logs must not fire the auto-sync. The
    /// auto-sync is expensive (HTTPS round-trip to the panel +
    /// engine restart) so false positives are real cost.
    func testDoesNotFireOnRegularConnectLog() {
        XCTAssertFalse(
            TunnelOrchestrator.isProxyAuthFailureLine(
                "[INFO] proxy connection established"))
        XCTAssertFalse(
            TunnelOrchestrator.isProxyAuthFailureLine(
                "Listening on 127.0.0.1:1080"))
        XCTAssertFalse(
            TunnelOrchestrator.isProxyAuthFailureLine(
                "[DEBUG] TLS handshake completed, cipher=TLS_AES_128_GCM_SHA256"))
    }

    /// Port numbers and byte counts can contain the substring
    /// "407" but in a position where neither side is a separator.
    /// Those must NOT fire — the boundary check is what
    /// distinguishes a status code from a coincidental digit run.
    func testDoesNotFireOnCoincidental407Substring() {
        XCTAssertFalse(
            TunnelOrchestrator.isProxyAuthFailureLine("bytes_in=2407123"))
        XCTAssertFalse(
            TunnelOrchestrator.isProxyAuthFailureLine("session=4078abc"))
        XCTAssertFalse(
            TunnelOrchestrator.isProxyAuthFailureLine("port 14073"))
    }

    /// Other HTTP status codes that share a digit prefix with 407
    /// (400, 401, 403, 404) must not be mis-attributed to auth.
    func testDoesNotConfuse407WithOther4xxCodes() {
        XCTAssertFalse(
            TunnelOrchestrator.isProxyAuthFailureLine("HTTP 401 Unauthorized"))
        XCTAssertFalse(
            TunnelOrchestrator.isProxyAuthFailureLine("HTTP 403 Forbidden"))
        XCTAssertFalse(
            TunnelOrchestrator.isProxyAuthFailureLine("HTTP 404 Not Found"))
        XCTAssertFalse(
            TunnelOrchestrator.isProxyAuthFailureLine("HTTP 400 Bad Request"))
    }

    func testDoesNotFireOnEmptyOrWhitespaceLine() {
        XCTAssertFalse(TunnelOrchestrator.isProxyAuthFailureLine(""))
        XCTAssertFalse(TunnelOrchestrator.isProxyAuthFailureLine("   "))
        XCTAssertFalse(TunnelOrchestrator.isProxyAuthFailureLine("\n"))
    }
}
