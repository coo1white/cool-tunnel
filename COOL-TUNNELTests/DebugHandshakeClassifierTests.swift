// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//
// COOL-TUNNELTests/DebugHandshakeClassifierTests.swift
//
// Pins the byte-pattern classifier on `DebugHandshakeReport` —
// the post-v2.0.53 surface that turns "200 OK then RST"
// (egress-blocked) into an actionable operator hint instead of
// a raw `Connection reset by peer` line the operator can't act on.
//
// The classifier is `nonisolated` and pure, so the tests don't
// need a MainActor hop. The byte patterns mirror exactly what
// the operator's debug-handshake log surfaced in the field —
// `HTTP/1.1 200 OK` + Padding header + RST = vpsEgressBlocked.

import XCTest

@testable import Cool_Tunnel

final class DebugHandshakeClassifierTests: XCTestCase {

    // MARK: - Fixtures

    /// Hex-encoded `HTTP/1.1 200 OK\r\nPadding: …\r\n\r\n` —
    /// what NaiveProxy's forward_proxy returns when it accepts
    /// the CONNECT. Operator's real log showed exactly this
    /// shape before the upstream RSTed.
    private static let receivedHex200 =
        "48 54 54 50 2f 31 2e 31 20 32 30 30 20 4f 4b 0d 0a "
        + "50 61 64 64 69 6e 67 3a 20 2c 3b 3e 0d 0a 0d 0a"

    /// Hex-encoded `HTTP/1.1 407 Proxy Authentication Required`.
    private static let receivedHex407 =
        "48 54 54 50 2f 31 2e 31 20 34 30 37 20 50 72 6f 78 79"

    private func makeReport(
        ok: Bool = false,
        connectOk: Bool = true,
        postConnectBytes: UInt64 = 0,
        receivedHex: String = "",
        error: String? = nil
    ) -> DebugHandshakeReport {
        DebugHandshakeReport(
            server: "test.example.com:443",
            target: "www.example.com:443",
            ok: ok,
            connectOk: connectOk,
            postConnectReceivedBytes: postConnectBytes,
            elapsedMs: 300,
            localSentHex: "",
            localReceivedHex: receivedHex,
            naiveStdout: [],
            naiveStderr: [],
            error: error
        )
    }

    // MARK: - ok == true → no classification

    func testSuccessfulHandshakeReturnsNilClassification() {
        let report = makeReport(ok: true, postConnectBytes: 42)
        XCTAssertNil(report.failureClassification)
    }

    // MARK: - connectFailed

    func testConnectOkFalseClassifiesAsConnectFailed() {
        let report = makeReport(connectOk: false)
        XCTAssertEqual(report.failureClassification, .connectFailed)
    }

    func testConnectFailedHintMentionsCurlAndDomain() {
        let hint = DebugHandshakeFailureClass.connectFailed.operatorHint
        XCTAssertTrue(hint.contains("Couldn't reach the proxy"))
        XCTAssertTrue(hint.contains("curl"))
    }

    // MARK: - proxyAuthRejected

    func testHttp407ResponseClassifiesAsProxyAuthRejected() {
        let report = makeReport(receivedHex: Self.receivedHex407)
        XCTAssertEqual(report.failureClassification, .proxyAuthRejected)
    }

    func testProxyAuthHintMentionsCredentialsAndSubscription() {
        let hint = DebugHandshakeFailureClass.proxyAuthRejected.operatorHint
        XCTAssertTrue(hint.contains("407"))
        XCTAssertTrue(hint.contains("subscription"))
    }

    // MARK: - vpsEgressBlocked — the operator's actual symptom

    /// Reproduces the operator's real log: `200 OK + Padding header`
    /// + `post_connect_received_bytes == 0` + "Connection reset by
    /// peer (os error 54)". This is THE pattern the post-v2.0.53
    /// classifier was added to recognise.
    func testTwoHundredOkPlusZeroPostConnectPlusResetClassifiesAsVpsEgressBlocked() {
        let report = makeReport(
            postConnectBytes: 0,
            receivedHex: Self.receivedHex200,
            error: "post-CONNECT read failed: Connection reset by peer (os error 54)"
        )
        XCTAssertEqual(report.failureClassification, .vpsEgressBlocked)
    }

    /// Linux variants of the same condition (ECONNRESET = errno 104
    /// vs macOS's 54) must also classify correctly. The Rust core
    /// can be compiled for Linux when run in the engine-server
    /// mode and surface the Linux errno verbatim.
    func testTwoHundredOkPlusLinuxEconnresetClassifiesAsVpsEgressBlocked() {
        let report = makeReport(
            postConnectBytes: 0,
            receivedHex: Self.receivedHex200,
            error: "post-CONNECT read failed: ECONNRESET (os error 104)"
        )
        XCTAssertEqual(report.failureClassification, .vpsEgressBlocked)
    }

    func testConnectionRefusedAfterTwoHundredOkClassifiesAsVpsEgressBlocked() {
        let report = makeReport(
            postConnectBytes: 0,
            receivedHex: Self.receivedHex200,
            error: "connection refused"
        )
        XCTAssertEqual(report.failureClassification, .vpsEgressBlocked)
    }

    func testVpsEgressHintMentionsVpsAndCurl() {
        let hint = DebugHandshakeFailureClass.vpsEgressBlocked.operatorHint
        XCTAssertTrue(hint.contains("VPS"))
        XCTAssertTrue(hint.contains("curl"))
        XCTAssertTrue(hint.contains("egress"))
    }

    // MARK: - other (unrecognised)

    /// `200 OK` + zero post-connect bytes but NO error string =
    /// unrecognised. The classifier doesn't guess; the operator
    /// gets the `.other` hint suggesting they read the byte dump.
    func testTwoHundredOkWithoutErrorClassifiesAsOther() {
        let report = makeReport(postConnectBytes: 0, receivedHex: Self.receivedHex200)
        XCTAssertEqual(report.failureClassification, .other)
    }

    /// `200 OK` + post-connect bytes received but ok=false =
    /// unrecognised. Something fell over after the upstream started
    /// streaming — not the egress-blocked shape.
    func testTwoHundredOkWithPostConnectBytesClassifiesAsOther() {
        let report = makeReport(
            postConnectBytes: 1024,
            receivedHex: Self.receivedHex200,
            error: "read truncated"
        )
        XCTAssertEqual(report.failureClassification, .other)
    }

    func testOtherHintMentionsByteDump() {
        let hint = DebugHandshakeFailureClass.other.operatorHint
        XCTAssertTrue(hint.contains("byte"))
    }

    // MARK: - isConnectionResetError — the matcher behind vpsEgressBlocked

    func testIsConnectionResetMatchesMacosErrno54() {
        XCTAssertTrue(
            DebugHandshakeReport.isConnectionResetError(
                "post-CONNECT read failed: Connection reset by peer (os error 54)"))
    }

    func testIsConnectionResetMatchesLinuxErrno104() {
        XCTAssertTrue(
            DebugHandshakeReport.isConnectionResetError("ECONNRESET (os error 104)"))
    }

    func testIsConnectionResetMatchesBrokenPipe() {
        XCTAssertTrue(
            DebugHandshakeReport.isConnectionResetError("write failed: broken pipe"))
    }

    func testIsConnectionResetMatchesUnexpectedEof() {
        XCTAssertTrue(
            DebugHandshakeReport.isConnectionResetError("unexpected EOF on stream"))
    }

    func testIsConnectionResetReturnsFalseForUnrelatedError() {
        XCTAssertFalse(
            DebugHandshakeReport.isConnectionResetError("TLS handshake failed: bad certificate"))
    }

    func testIsConnectionResetReturnsFalseForNil() {
        XCTAssertFalse(DebugHandshakeReport.isConnectionResetError(nil))
    }
}
