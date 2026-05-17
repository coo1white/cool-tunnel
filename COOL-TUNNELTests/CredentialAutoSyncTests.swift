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
//
// **v3.0.0 (sub-phase F):** Profile construction uses the new
// `uuid` + `reality` shape. Codable round-trip tests still
// exercise the same persistence contract (the
// `subscriptionURL` field's Codable handling is the load-bearing
// surface), they just carry different bytes in the secret slot.

import XCTest

@testable import Cool_Tunnel

final class CredentialAutoSyncTests: XCTestCase {

    // MARK: - Profile.subscriptionURL Codable

    func testProfileSubscriptionURLRoundTripsThroughJSON() throws {
        let original = Profile(
            id: "test",
            server: "proxy.example.com",
            username: "alice",
            uuid: "11111111-2222-3333-4444-555555555555",
            reality: ProfileReality(
                publicKey: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                destHost: "www.microsoft.com",
                shortId: "01ab"
            ),
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
    ///
    /// **v3.0.0 (sub-phase F):** the legacy JSON below uses the
    /// v3.0.0 shape (`uuid` + `reality`) — a v2.x blob carrying
    /// `password` won't decode here, and the user goes through the
    /// `Pers-F#10` corrupt-blob backup path (which sub-phase G
    /// will add an explicit regression test for).
    func testProfileDecodesLegacyJSONWithoutSubscriptionURL() throws {
        let legacyJSON = """
            {
              "id": "default",
              "server": "proxy.example.com",
              "username": "alice",
              "uuid": "11111111-2222-3333-4444-555555555555",
              "reality": {
                "public_key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                "dest_host": "www.microsoft.com",
                "short_id": "01ab"
              },
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
    /// Profiles without it compile unchanged.
    func testProfileDefaultStillHasNoSubscriptionURL() {
        XCTAssertNil(Profile.default.subscriptionURL)
    }

    // MARK: - isProxyAuthFailureLine — positive cases

    /// Chromium-style `ERR_PROXY_AUTH_REQUESTED` is the canonical
    /// signal NaiveProxy emits when upstream returns 407 — kept
    /// in the v3.0.0 matcher for support transcripts handed
    /// across the upgrade window.
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

    // MARK: - VLESS+Reality auth chips (v3.0.0 sub-phase F)

    /// sing-box surfaces a failed Reality handshake with the
    /// `reality handshake failed` chip — typically a Reality
    /// public_key mismatch between client and server. Auto-sync
    /// fires because re-fetching the subscription URL is the
    /// right next operator step.
    func testDetectsRealityHandshakeFailure() {
        XCTAssertTrue(
            TunnelOrchestrator.isProxyAuthFailureLine(
                "[ERROR] reality handshake failed: invalid auth"))
    }

    /// `unknown vless user` fires when the VLESS UUID doesn't
    /// match any account on the server. Same auto-sync flow.
    func testDetectsUnknownVlessUser() {
        XCTAssertTrue(
            TunnelOrchestrator.isProxyAuthFailureLine(
                "outbound rejected: unknown vless user 11111111-…"))
    }

    /// `vless user not found` is the alternate wording some
    /// sing-box upstream tags use; cover it explicitly.
    func testDetectsVlessUserNotFound() {
        XCTAssertTrue(
            TunnelOrchestrator.isProxyAuthFailureLine(
                "[error] vless: user not found"))
        XCTAssertTrue(
            TunnelOrchestrator.isProxyAuthFailureLine(
                "vless user not found in users table"))
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
