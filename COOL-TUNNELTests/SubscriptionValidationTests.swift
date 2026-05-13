// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
// COOL-TUNNELTests/SubscriptionValidationTests.swift
//
// Regression coverage for the two security-trust gates inside
// `SubscriptionManifestV1`:
//
//   - `validate(now:)` — enforces every documented invariant on a
//     panel-imported manifest. Counterfeit / hijacked panels are
//     an explicit threat model in the file-header comment.
//
//   - `isBlockedHost(_:)` — SSRF protection. A counterfeit panel
//     returning `host: "127.0.0.1:8080"` (or any private / link-
//     local / loopback shape) would otherwise direct naive at
//     whatever local service was listening. Recognises hostname
//     forms (localhost, *.local), IPv4 dotted-quad against every
//     RFC 1918 / loopback / link-local block, and bracketed IPv6
//     literals (::1, fe80::, fc00::, fd00::).
//
// Every documented invariant gets one test that names the rule
// it violates so a future regression has a clear log signal.
// `now:` is injected throughout so tests don't depend on
// wall-clock time.

import XCTest

@testable import Cool_Tunnel

final class SubscriptionValidationTests: XCTestCase {

    // MARK: - Fixtures

    /// Reference `now`. Picked far enough into the past that we can
    /// build manifests with `issuedAt < now` for the staleness/
    /// expiry tests without underflowing UInt64.
    private static let referenceNow = Date(timeIntervalSince1970: 1_750_000_000)

    /// `now` as the wire-format UInt64 seconds-since-epoch.
    private static var referenceNowSecs: UInt64 {
        UInt64(referenceNow.timeIntervalSince1970)
    }

    /// Builds a manifest with every documented invariant satisfied.
    /// Each test mutates one field to violate one rule.
    private func validManifest(
        version: UInt32 = 1,
        server: String = "proxy.example.com",
        profiles: [SubscriptionProfileV1]? = nil,
        capabilities: ServerCapabilitiesV1? = nil,
        issuedAt: UInt64? = nil,
        expiresAt: UInt64? = nil
    ) -> SubscriptionManifestV1 {
        SubscriptionManifestV1(
            version: version,
            server: server,
            profiles: profiles ?? [validProfile()],
            capabilities: capabilities ?? validCapabilities(),
            issuedAt: issuedAt ?? Self.referenceNowSecs &- 60,  // issued 60s ago
            expiresAt: expiresAt ?? Self.referenceNowSecs &+ (24 * 60 * 60),  // 24h from now
            note: nil,
            signature: nil
        )
    }

    private func validProfile(host: String = "proxy.example.com") -> SubscriptionProfileV1 {
        SubscriptionProfileV1(
            host: host, port: 443, username: "user", password: "pwd", label: nil
        )
    }

    private func validCapabilities(http3: Bool = false) -> ServerCapabilitiesV1 {
        ServerCapabilitiesV1(antiTracking: [.hideIp], http3: http3, fakeSiteSlug: nil)
    }

    // MARK: - validate() happy path

    func testValidateAcceptsAWellFormedManifest() throws {
        let manifest = validManifest()
        XCTAssertNoThrow(try manifest.validate(now: Self.referenceNow))
    }

    // MARK: - validate() — version

    func testValidateRejectsUnsupportedVersion() {
        let manifest = validManifest(version: 2)
        XCTAssertThrowsError(try manifest.validate(now: Self.referenceNow)) { error in
            guard case SubscriptionValidationError.unsupportedVersion(let got, let expected) = error
            else {
                return XCTFail("expected unsupportedVersion, got \(error)")
            }
            XCTAssertEqual(got, 2)
            XCTAssertEqual(expected, 1)
        }
    }

    // MARK: - validate() — profile cardinality

    func testValidateRejectsEmptyProfileList() {
        let manifest = validManifest(profiles: [])
        XCTAssertThrowsError(try manifest.validate(now: Self.referenceNow)) { error in
            guard case SubscriptionValidationError.noProfiles = error else {
                return XCTFail("expected noProfiles, got \(error)")
            }
        }
    }

    func testValidateRejectsProfileFloodAboveCap() {
        let profiles = Array(
            repeating: validProfile(), count: SubscriptionManifestV1.maxProfiles + 1
        )
        let manifest = validManifest(profiles: profiles)
        XCTAssertThrowsError(try manifest.validate(now: Self.referenceNow)) { error in
            guard case SubscriptionValidationError.tooManyProfiles(let got, let max) = error else {
                return XCTFail("expected tooManyProfiles, got \(error)")
            }
            XCTAssertEqual(got, SubscriptionManifestV1.maxProfiles + 1)
            XCTAssertEqual(max, SubscriptionManifestV1.maxProfiles)
        }
    }

    func testValidateAcceptsExactlyMaxProfiles() throws {
        let profiles = Array(
            repeating: validProfile(), count: SubscriptionManifestV1.maxProfiles
        )
        let manifest = validManifest(profiles: profiles)
        XCTAssertNoThrow(try manifest.validate(now: Self.referenceNow))
    }

    // MARK: - validate() — blocked host (SSRF gate)

    /// Hits the `isBlockedHost` path through `validate`. The
    /// dedicated unit tests below cover the host classifier
    /// exhaustively; this confirms the wiring fires
    /// `blockedHost(_:)` from `validate(now:)` itself.
    func testValidateRejectsProfileWithBlockedHost() {
        let manifest = validManifest(profiles: [validProfile(host: "127.0.0.1")])
        XCTAssertThrowsError(try manifest.validate(now: Self.referenceNow)) { error in
            guard case SubscriptionValidationError.blockedHost(let host) = error else {
                return XCTFail("expected blockedHost, got \(error)")
            }
            XCTAssertEqual(host, "127.0.0.1")
        }
    }

    // MARK: - validate() — counterfeit-capability heuristic

    func testValidateRejectsHttp3AdvertisedCapability() {
        let manifest = validManifest(capabilities: validCapabilities(http3: true))
        XCTAssertThrowsError(try manifest.validate(now: Self.referenceNow)) { error in
            guard case SubscriptionValidationError.counterfeitCapabilities = error else {
                return XCTFail("expected counterfeitCapabilities, got \(error)")
            }
        }
    }

    // MARK: - validate() — issuedAt sentinel + forward skew

    func testValidateRejectsZeroIssuedAt() {
        let manifest = validManifest(issuedAt: 0, expiresAt: Self.referenceNowSecs &+ 60)
        XCTAssertThrowsError(try manifest.validate(now: Self.referenceNow)) { error in
            guard case SubscriptionValidationError.invalidIssuedAt = error else {
                return XCTFail("expected invalidIssuedAt, got \(error)")
            }
        }
    }

    func testValidateRejectsFutureIssuedAtBeyondSkewWindow() {
        // 5 minutes into the future — well outside the 60s window.
        let manifest = validManifest(
            issuedAt: Self.referenceNowSecs &+ 5 * 60,
            expiresAt: Self.referenceNowSecs &+ 24 * 60 * 60
        )
        XCTAssertThrowsError(try manifest.validate(now: Self.referenceNow)) { error in
            guard case SubscriptionValidationError.invalidIssuedAt = error else {
                return XCTFail("expected invalidIssuedAt for far-future issuedAt, got \(error)")
            }
        }
    }

    func testValidateAcceptsIssuedAtInsideSkewWindow() throws {
        // 30s into the future — inside the 60s skew tolerance.
        let manifest = validManifest(
            issuedAt: Self.referenceNowSecs &+ 30,
            expiresAt: Self.referenceNowSecs &+ 24 * 60 * 60
        )
        XCTAssertNoThrow(try manifest.validate(now: Self.referenceNow))
    }

    // MARK: - validate() — expiry ordering + validity-window cap

    func testValidateRejectsExpiresBeforeIssued() {
        let issued = Self.referenceNowSecs &- 60
        let manifest = validManifest(issuedAt: issued, expiresAt: issued &- 1)
        XCTAssertThrowsError(try manifest.validate(now: Self.referenceNow)) { error in
            guard case SubscriptionValidationError.malformedExpiry = error else {
                return XCTFail("expected malformedExpiry, got \(error)")
            }
        }
    }

    func testValidateRejectsValidityWindowBeyondOneYear() {
        let issued = Self.referenceNowSecs &- 60
        // 366 days — exceeds the 365-day cap.
        let manifest = validManifest(
            issuedAt: issued,
            expiresAt: issued &+ 366 * 24 * 60 * 60
        )
        XCTAssertThrowsError(try manifest.validate(now: Self.referenceNow)) { error in
            guard case SubscriptionValidationError.validityTooLong(let got, let max) = error else {
                return XCTFail("expected validityTooLong, got \(error)")
            }
            XCTAssertGreaterThan(got, max)
            XCTAssertEqual(max, SubscriptionManifestV1.maxValidity)
        }
    }

    func testValidateAcceptsValidityAtExactlyOneYear() throws {
        let issued = Self.referenceNowSecs &- 60
        let manifest = validManifest(
            issuedAt: issued,
            expiresAt: issued &+ SubscriptionManifestV1.maxValidity
        )
        XCTAssertNoThrow(try manifest.validate(now: Self.referenceNow))
    }

    /// Overflow safety on the validity-window cap. The validator
    /// uses `addingReportingOverflow` and saturates to `UInt64.max`
    /// on overflow; this test pairs a near-max `issuedAt` with
    /// `expiresAt = UInt64.max` and confirms the path doesn't
    /// crash or wrap-and-accept.
    func testValidateOverflowSafeAtUInt64Max() {
        // `issuedAt` close to UInt64.max so the cap computation
        // would overflow. We don't actually expect this manifest to
        // pass — the future-skew gate rejects it first — but the
        // important thing is that the validator doesn't panic on
        // the overflow path.
        let manifest = validManifest(
            issuedAt: UInt64.max &- 10,
            expiresAt: UInt64.max
        )
        XCTAssertThrowsError(try manifest.validate(now: Self.referenceNow)) { error in
            // The future-skew gate fires first; just confirm we
            // arrive at SOME validation error rather than crashing.
            XCTAssertTrue(error is SubscriptionValidationError)
        }
    }

    // MARK: - validate() — expired

    func testValidateRejectsExpiredManifest() {
        let issued = Self.referenceNowSecs &- 7200  // 2 hours ago
        let expired = Self.referenceNowSecs &- 60  // 1 minute ago
        let manifest = validManifest(issuedAt: issued, expiresAt: expired)
        XCTAssertThrowsError(try manifest.validate(now: Self.referenceNow)) { error in
            guard case SubscriptionValidationError.expired(let at) = error else {
                return XCTFail("expected expired, got \(error)")
            }
            XCTAssertEqual(at, expired)
        }
    }

    // MARK: - validate() — staleness (freshness gate)

    func testValidateRejectsManifestOlderThanMaxAge() {
        // Issued 8 days ago — beyond the 7-day max age, even though
        // not yet expired.
        let issued = Self.referenceNowSecs &- 8 * 24 * 60 * 60
        let expiresAt = Self.referenceNowSecs &+ 24 * 60 * 60  // still in the future
        let manifest = validManifest(issuedAt: issued, expiresAt: expiresAt)
        XCTAssertThrowsError(try manifest.validate(now: Self.referenceNow)) { error in
            guard case SubscriptionValidationError.stale(let age) = error else {
                return XCTFail("expected stale, got \(error)")
            }
            XCTAssertGreaterThan(age, SubscriptionManifestV1.maxAge)
        }
    }

    func testValidateAcceptsManifestAtExactlyMaxAge() throws {
        // Exactly maxAge old, not stale (the boundary is `>`, not `>=`).
        let issued = Self.referenceNowSecs &- UInt64(SubscriptionManifestV1.maxAge)
        let expiresAt = issued &+ UInt64(SubscriptionManifestV1.maxAge) &+ 60
        let manifest = validManifest(issuedAt: issued, expiresAt: expiresAt)
        XCTAssertNoThrow(try manifest.validate(now: Self.referenceNow))
    }

    // MARK: - isBlockedHost — hostname forms

    func testIsBlockedHostBlocksLocalhost() {
        XCTAssertTrue(SubscriptionManifestV1.isBlockedHost("localhost"))
        XCTAssertTrue(SubscriptionManifestV1.isBlockedHost("LOCALHOST"))  // case-insensitive
        XCTAssertTrue(SubscriptionManifestV1.isBlockedHost("  localhost  "))  // whitespace
    }

    func testIsBlockedHostBlocksDotLocalMdns() {
        XCTAssertTrue(SubscriptionManifestV1.isBlockedHost("myhost.local"))
        XCTAssertTrue(SubscriptionManifestV1.isBlockedHost("apple.tv.local"))
        XCTAssertTrue(SubscriptionManifestV1.isBlockedHost("local"))
    }

    func testIsBlockedHostBlocksEmptyAndWhitespace() {
        XCTAssertTrue(SubscriptionManifestV1.isBlockedHost(""))
        XCTAssertTrue(SubscriptionManifestV1.isBlockedHost("   "))
    }

    // MARK: - isBlockedHost — IPv4 private / loopback / link-local

    func testIsBlockedHostBlocksLoopbackIPv4() {
        for host in ["127.0.0.1", "127.255.255.254"] {
            XCTAssertTrue(
                SubscriptionManifestV1.isBlockedHost(host),
                "\(host) should be blocked (127/8 loopback)")
        }
    }

    func testIsBlockedHostBlocksRFC1918Ranges() {
        for host in [
            "10.0.0.1", "10.255.255.255",  // 10/8
            "172.16.0.1", "172.31.255.255",  // 172.16/12
            "192.168.0.1", "192.168.255.255",  // 192.168/16
        ] {
            XCTAssertTrue(
                SubscriptionManifestV1.isBlockedHost(host),
                "\(host) should be blocked (RFC 1918)")
        }
    }

    func testIsBlockedHostBlocksLinkLocalAndUnspecifiedIPv4() {
        XCTAssertTrue(SubscriptionManifestV1.isBlockedHost("169.254.1.1"))
        XCTAssertTrue(SubscriptionManifestV1.isBlockedHost("0.0.0.0"))
    }

    /// Boundary check: 172.15.x.x and 172.32.x.x are NOT private
    /// (the 172/12 range is 172.16-31 only). Pre-fix bugs in CIDR
    /// classifiers often expand this range incorrectly.
    func testIsBlockedHostAcceptsAdjacentToPrivate172Range() {
        XCTAssertFalse(SubscriptionManifestV1.isBlockedHost("172.15.255.255"))
        XCTAssertFalse(SubscriptionManifestV1.isBlockedHost("172.32.0.0"))
    }

    func testIsBlockedHostAcceptsPublicIPv4() {
        for host in ["8.8.8.8", "1.1.1.1", "203.0.113.1", "11.0.0.1"] {
            XCTAssertFalse(
                SubscriptionManifestV1.isBlockedHost(host),
                "\(host) should be allowed (public IPv4)")
        }
    }

    // MARK: - isBlockedHost — IPv6 bracketed literals

    func testIsBlockedHostBlocksIPv6Loopback() {
        XCTAssertTrue(SubscriptionManifestV1.isBlockedHost("[::1]"))
        XCTAssertTrue(SubscriptionManifestV1.isBlockedHost("[::]"))
    }

    func testIsBlockedHostBlocksIPv6LinkLocalAndULA() {
        // fe80::/10 — link-local
        XCTAssertTrue(SubscriptionManifestV1.isBlockedHost("[fe80::1]"))
        // fc00::/7 — unique local addresses
        XCTAssertTrue(SubscriptionManifestV1.isBlockedHost("[fc00::1]"))
        XCTAssertTrue(SubscriptionManifestV1.isBlockedHost("[fd00::1]"))
    }

    func testIsBlockedHostAcceptsPublicIPv6() {
        // Documentation prefix 2001:db8::/32 — globally reserved but
        // not private. Real public IPv6 (Google DNS) follows.
        XCTAssertFalse(SubscriptionManifestV1.isBlockedHost("[2001:db8::1]"))
        XCTAssertFalse(SubscriptionManifestV1.isBlockedHost("[2001:4860:4860::8888]"))
    }

    // MARK: - isBlockedHost — public hostnames

    func testIsBlockedHostAcceptsPublicHostnames() {
        for host in [
            "proxy.example.com",
            "my-vps.coolwhite.com",
            "edge.cloudflare.net",
            "tunnel-2.example.org",
        ] {
            XCTAssertFalse(
                SubscriptionManifestV1.isBlockedHost(host),
                "\(host) should be allowed (public hostname)")
        }
    }
}
