// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
// COOL-TUNNELTests/GitHubTrustTests.swift
//
// Fail-closed coverage for the shared GitHub trust boundary the
// three updaters lean on (`AppUpdater`, `SingboxUpdater`,
// `RustCoreUpdater`). Pins:
//
//   - `isTrustedGitHubURL(_:)` accepts ONLY https + the explicit
//     `github.com` / `githubusercontent.com` suffix list. Every
//     anomaly — http downgrade, sibling host, look-alike host,
//     missing host, suffix-injection attempt — must be rejected.
//
//   - `GitHubRedirectGuard.download(url:to:)` rejects an untrusted
//     URL BEFORE the URLSession call. Verified by passing a URL
//     whose host the trust gate refuses; the function must throw
//     `UntrustedGitHubHostError` without any network traffic.
//
// Tests deliberately do NOT stub `URLSession`. The size-cap and
// fail-closed-on-stat-error paths live behind the network boundary
// and would require URLProtocol stubbing to exercise. The
// `AppUpdater` size-cap (PR #55) shares the same pattern and is
// already verified by code review + the production-side
// `audit.sh` security_check.sh pass.

import XCTest

@testable import Cool_Tunnel

final class GitHubTrustTests: XCTestCase {

    // MARK: - isTrustedGitHubURL — accept list

    func testAcceptsBareGitHubCom() {
        XCTAssertTrue(isTrustedGitHubURL(URL(string: "https://github.com/owner/repo")!))
    }

    func testAcceptsApiGitHubCom() {
        XCTAssertTrue(
            isTrustedGitHubURL(
                URL(string: "https://api.github.com/repos/coo1white/cool-tunnel/releases/latest")!)
        )
    }

    func testAcceptsGitHubUserContent() {
        XCTAssertTrue(
            isTrustedGitHubURL(
                URL(string: "https://objects.githubusercontent.com/raw/x.tar.gz")!)
        )
    }

    func testAcceptsBareGitHubUserContent() {
        XCTAssertTrue(
            isTrustedGitHubURL(URL(string: "https://githubusercontent.com/whatever")!)
        )
    }

    // MARK: - isTrustedGitHubURL — reject list

    /// HTTPS is non-negotiable. A release URL that downgrades to
    /// `http://` is rejected outright — this is the TLS-strip
    /// defense.
    func testRejectsHttpScheme() {
        XCTAssertFalse(isTrustedGitHubURL(URL(string: "http://github.com/x")!))
    }

    func testRejectsNonHttpScheme() {
        for url in [
            "ftp://github.com/x",
            "file:///etc/passwd",
            "data:text/plain,hello",
            "javascript:alert(1)",
        ] {
            XCTAssertFalse(
                isTrustedGitHubURL(URL(string: url)!),
                "\(url) was accepted but should be rejected")
        }
    }

    /// The suffix check uses `host == suffix || host.hasSuffix("." + suffix)`.
    /// Look-alike hosts (the same suffix as a substring but at the
    /// wrong boundary) must NOT match.
    func testRejectsLookalikeHosts() {
        for url in [
            "https://evilgithub.com/x",
            "https://github.com.evil.com/x",
            "https://notgithubusercontent.com/x",
            "https://githubusercontent.com.attacker.org/x",
        ] {
            XCTAssertFalse(
                isTrustedGitHubURL(URL(string: url)!),
                "\(url) was accepted but should be rejected (look-alike)")
        }
    }

    /// IP-literal hosts that happen to dot-match the suffix shape
    /// must be rejected. Defense against a hijacked DNS resolver.
    func testRejectsIPLiteralHosts() {
        for url in [
            "https://192.168.1.1/x",
            "https://10.0.0.1/x",
            "https://[::1]/x",
        ] {
            XCTAssertFalse(
                isTrustedGitHubURL(URL(string: url)!),
                "\(url) was accepted but should be rejected (IP literal)")
        }
    }

    /// Sibling project hosts on GitHub Pages / Gist / etc. are
    /// outside the trust boundary the updater anchors on. They
    /// LOOK GitHub-shaped but are user-controlled content surfaces.
    func testRejectsSiblingGitHubServicesOutsideTheSuffixList() {
        for url in [
            "https://gist.github.io/owner/asset",  // github.io, not github.com
            "https://owner.github.io/repo/release.zip",
            "https://raw.example.com/cool-tunnel/release.zip",
        ] {
            XCTAssertFalse(
                isTrustedGitHubURL(URL(string: url)!),
                "\(url) was accepted but should be rejected (sibling service)")
        }
    }

    // MARK: - GitHubRedirectGuard.download — fail-closed gate

    /// The trust check happens BEFORE any network call. A URL whose
    /// host fails the gate must throw `UntrustedGitHubHostError`
    /// without contacting the network. We verify the throw shape;
    /// network-call absence is implicit (an actual network call to a
    /// non-existent host would time out, not throw immediately).
    func testDownloadRejectsUntrustedHostBeforeNetworkCall() async {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cool-tunnel-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(  // try-ok: best-effort test fixture setup
            at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }  // try-ok: test-fixture teardown

        let destination = tempDir.appendingPathComponent("payload.bin")
        let untrustedURL = URL(string: "https://evil.example.com/payload")!

        do {
            _ = try await GitHubRedirectGuard.download(url: untrustedURL, to: destination)
            XCTFail("expected UntrustedGitHubHostError, got success")
        } catch let error as UntrustedGitHubHostError {
            XCTAssertEqual(error.url, untrustedURL)
        } catch {
            XCTFail("expected UntrustedGitHubHostError, got \(type(of: error)): \(error)")
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.path),
            "fail-closed: no file must land at destination on a rejected URL")
    }

    /// The HTTP-downgrade rejection holds at the download seam too.
    func testDownloadRejectsHttpDowngradeBeforeNetworkCall() async {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cool-tunnel-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(  // try-ok: best-effort test fixture setup
            at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }  // try-ok: test-fixture teardown

        let destination = tempDir.appendingPathComponent("payload.bin")
        // Trusted host but http:// — must be rejected by the scheme guard.
        let httpURL = URL(string: "http://github.com/owner/repo/releases/download/v1/x.zip")!

        do {
            _ = try await GitHubRedirectGuard.download(url: httpURL, to: destination)
            XCTFail("expected UntrustedGitHubHostError, got success")
        } catch is UntrustedGitHubHostError {
            // expected
        } catch {
            XCTFail("expected UntrustedGitHubHostError, got \(type(of: error)): \(error)")
        }
    }
}
