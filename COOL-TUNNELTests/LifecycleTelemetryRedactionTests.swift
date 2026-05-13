// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
// COOL-TUNNELTests/LifecycleTelemetryRedactionTests.swift
//
// Regression coverage for the Swift-side telemetry redaction. The
// telemetry file lives at 0600 inside Application Support, but
// support transcripts, Time Machine snapshots, and screenshots
// move it around — anything credential-shaped that reaches the
// file is at real risk of escaping the user's control.
//
// The Rust core's `redaction::redact` is the canonical impl;
// `LifecycleTelemetryLogger.redact` mirrors its regex categories
// so a string the engine already redacted stays redacted on the
// Swift side, AND strings that arrive only via Swift (e.g. a
// `URLError.localizedDescription` wrapping a userinfo-bearing
// URL, a Foundation error embedding an `Authorization:` header
// from a misbehaving reverse proxy) get stripped before reaching
// disk.
//
// Every category from the Rust impl gets a test here. Where the
// behavior diverges intentionally, the test explains why.

import XCTest

@testable import Cool_Tunnel

final class LifecycleTelemetryRedactionTests: XCTestCase {

    // MARK: - Sanity

    func testRedactionRulesCompile() {
        // Touches the lazy regex array. A bad regex would
        // `fatalError` at first use; this test forces that first
        // use during the suite rather than after release.
        _ = LifecycleTelemetryLogger.redact("noise")
    }

    func testPassesCleanLineThrough() {
        let line = "engine.state.running mode=Smart pid=12345"
        XCTAssertEqual(LifecycleTelemetryLogger.redact(line), line)
    }

    func testEmptyStringIsSafe() {
        XCTAssertEqual(LifecycleTelemetryLogger.redact(""), "")
    }

    // MARK: - Userinfo / scheme://user:pass@host

    func testRedactsHttpsUserinfo() {
        let line = "Listening: https://nick:hunter2@naive.example.com:443"
        let out = LifecycleTelemetryLogger.redact(line)
        XCTAssertFalse(out.contains("hunter2"), "password leaked: \(out)")
        XCTAssertFalse(out.contains("nick"), "username leaked: \(out)")
        XCTAssertTrue(out.contains("***:***@naive.example.com"), "shape wrong: \(out)")
    }

    func testRedactsSocksVariants() {
        for line in [
            "socks5://nick:hunter2@proxy.example.com:1080",
            "socks5h://nick:hunter2@proxy.example.com:1080",
            "socks://nick:hunter2@proxy.example.com:1080",
            "socks4://nick:hunter2@proxy.example.com:1080",
            "socks4a://nick:hunter2@proxy.example.com:1080",
        ] {
            let out = LifecycleTelemetryLogger.redact(line)
            XCTAssertFalse(out.contains("hunter2"), "password leaked: \(out)")
        }
    }

    /// Multi-`@` userinfo (`user:p@ssword@host`). Greedy class
    /// strips the *whole* userinfo run instead of stopping at the
    /// first `@`. Mirrors the L2 fix on the Rust side.
    func testRedactsUserinfoWithEmbeddedAtSign() {
        let line = "https://user:p@ssword@host.example.com/path"
        let out = LifecycleTelemetryLogger.redact(line)
        XCTAssertFalse(out.contains("p@ssword"), "password tail leaked: \(out)")
        XCTAssertTrue(out.hasPrefix("https://***:***@host.example.com"), "shape wrong: \(out)")
    }

    /// Two URLs on one line each redact independently. The greedy
    /// class is bounded by `\s`, not by `@`, so the second URL's
    /// userinfo is matched as its own run.
    func testRedactsTwoUrlsIndependently() {
        let line = "from https://a:b@host1 to https://c:d@host2"
        let out = LifecycleTelemetryLogger.redact(line)
        XCTAssertFalse(out.contains("a:b"), "first creds leaked: \(out)")
        XCTAssertFalse(out.contains("c:d"), "second creds leaked: \(out)")
        XCTAssertEqual(
            out, "from https://***:***@host1 to https://***:***@host2",
            "shape wrong: \(out)")
    }

    func testDoesNotMatchAtSignOutsideURL() {
        let line = "user@host (not a URL)"
        XCTAssertEqual(LifecycleTelemetryLogger.redact(line), line)
    }

    // MARK: - Authorization headers

    func testRedactsAuthorizationHeader() {
        let line = "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig"
        let out = LifecycleTelemetryLogger.redact(line)
        XCTAssertFalse(out.contains("eyJhbGc"), "JWT leaked: \(out)")
        XCTAssertTrue(out.contains("Authorization: Bearer ***"), "shape wrong: \(out)")
    }

    func testRedactsProxyAuthorizationHeader() {
        let line = "Proxy-Authorization: Basic bmljazpodW50ZXIy"
        let out = LifecycleTelemetryLogger.redact(line)
        XCTAssertFalse(out.contains("bmljazpodW50ZXIy"), "Basic payload leaked: \(out)")
        XCTAssertTrue(out.contains("Proxy-Authorization: Basic ***"), "shape wrong: \(out)")
    }

    func testRedactsAuthorizationHeaderMixedCase() {
        for line in [
            "  proxy-authorization:   Bearer eyJhbGc...",
            "Proxy-Authorization:Basic abcdef==",
            "PROXY-AUTHORIZATION: Digest nonce=...",
        ] {
            let out = LifecycleTelemetryLogger.redact(line)
            XCTAssertFalse(
                out.contains("eyJhbGc") || out.contains("abcdef") || out.contains("nonce"),
                "credentials leaked: \(out)")
        }
    }

    // MARK: - Cookie / Set-Cookie

    func testRedactsCookieAndSetCookieHeaders() {
        for line in [
            "Cookie: session=abc123; csrf=def456",
            "Set-Cookie: session=abc123; HttpOnly; Secure",
        ] {
            let out = LifecycleTelemetryLogger.redact(line)
            XCTAssertFalse(out.contains("abc123"), "session token leaked: \(out)")
            XCTAssertTrue(out.contains("***"), "redaction marker missing: \(out)")
        }
    }

    // MARK: - JSON-shaped credentials (quoted)

    /// Quoted password with embedded space — the realistic case
    /// (human-typed credentials). Strict-JSON quoted matcher
    /// consumes through the closing quote.
    func testRedactsQuotedPasswordWithEmbeddedSpace() {
        let line = #"{"password":"Tr0ub4dor 3 cat-pic","other":"ok"}"#
        let out = LifecycleTelemetryLogger.redact(line)
        XCTAssertFalse(out.contains("Tr0ub4dor"), "password head leaked: \(out)")
        XCTAssertFalse(out.contains("cat-pic"), "password tail leaked: \(out)")
        XCTAssertTrue(out.contains(#""password":"***""#), "shape wrong: \(out)")
        XCTAssertTrue(out.contains(#""other":"ok""#), "non-cred field clobbered: \(out)")
    }

    func testRedactsQuotedPasswordWithEmbeddedComma() {
        let line = #"{"password":"foo,bar","u":"v"}"#
        let out = LifecycleTelemetryLogger.redact(line)
        XCTAssertFalse(out.contains("foo,bar"), "password leaked: \(out)")
        XCTAssertTrue(out.contains(#""password":"***""#), "shape wrong: \(out)")
        XCTAssertTrue(out.contains(#""u":"v""#), "non-cred field clobbered: \(out)")
    }

    func testRedactsQuotedTokenAndApiKey() {
        for line in [
            #"{"token":"abc123def"}"#,
            #"{"api_key":"sk-secret"}"#,
            #"{"refresh_token":"reftok"}"#,
        ] {
            let out = LifecycleTelemetryLogger.redact(line)
            XCTAssertFalse(
                out.contains("abc123def") || out.contains("sk-secret") || out.contains("reftok"),
                "token-shaped value leaked: \(out)")
        }
    }

    // MARK: - Bare k=v / k: v credentials

    func testRedactsBarePasswordAssignment() {
        for line in ["password=hunter2", "password: hunter2", "PASSWORD=hunter2"] {
            let out = LifecycleTelemetryLogger.redact(line)
            XCTAssertFalse(out.contains("hunter2"), "bare value leaked: \(out)")
            XCTAssertTrue(out.contains("***"), "redaction marker missing: \(out)")
        }
    }
}
