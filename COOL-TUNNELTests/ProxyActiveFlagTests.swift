// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
// COOL-TUNNELTests/ProxyActiveFlagTests.swift
//
// Pin the sentinel-file lifecycle that powers the post-crash
// system-proxy-disable recovery (Lifecycle-F#16). The sentinel
// is written when the orchestrator enables the system proxy and
// removed on clean disable; if it exists at bootstrap, the
// previous run did NOT cleanly disable and the orchestrator
// force-disables before any UI appears.
//
// A regression here is invisible until the user crashes — at
// which point the system proxy points at a non-listening port
// and every browser request stalls. These tests pin the
// observable contract so a refactor of `ProxyActiveFlag` is
// reviewer-visible.

import XCTest

@testable import Cool_Tunnel

final class ProxyActiveFlagTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cool-tunnel-flag-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var flagPath: URL {
        ProxyActiveFlag.path(in: tempDir)
    }

    // MARK: - existsIndicatingCrash

    /// Fresh directory has no sentinel → not indicating a crash.
    /// First-launch case.
    func testExistsReportsFalseOnFreshDirectory() {
        XCTAssertFalse(ProxyActiveFlag.existsIndicatingCrash(at: flagPath))
    }

    /// After write, the existence check fires. This is the path
    /// the orchestrator hits at bootstrap when the previous run
    /// crashed mid-Active.
    func testExistsReportsTrueAfterWrite() {
        ProxyActiveFlag.write(at: flagPath, mode: "Smart")
        XCTAssertTrue(ProxyActiveFlag.existsIndicatingCrash(at: flagPath))
    }

    /// After write-then-clear, the existence check fires false
    /// again. The orchestrator's clean-disable path runs
    /// `ProxyActiveFlag.clear`; this pins that the next launch
    /// sees a non-crashed state.
    func testExistsReportsFalseAfterClear() {
        ProxyActiveFlag.write(at: flagPath, mode: "Smart")
        ProxyActiveFlag.clear(at: flagPath)
        XCTAssertFalse(ProxyActiveFlag.existsIndicatingCrash(at: flagPath))
    }

    // MARK: - clear() idempotency

    /// Clearing a missing sentinel is success, not throw. The
    /// orchestrator's shutdown path can call `clear` without
    /// caring whether the sentinel was written in the first
    /// place (e.g., orchestrator transitioned through `.localOnly`
    /// which never enabled system proxy).
    func testClearIsIdempotentOnMissingFile() {
        // No file ever written.
        ProxyActiveFlag.clear(at: flagPath)
        // Calling again is also fine.
        ProxyActiveFlag.clear(at: flagPath)
        XCTAssertFalse(ProxyActiveFlag.existsIndicatingCrash(at: flagPath))
    }

    /// Clearing the sentinel and then clearing again is also
    /// idempotent.
    func testClearAfterClearIsIdempotent() {
        ProxyActiveFlag.write(at: flagPath, mode: "Global")
        ProxyActiveFlag.clear(at: flagPath)
        // Second clear when file already gone.
        ProxyActiveFlag.clear(at: flagPath)
        XCTAssertFalse(ProxyActiveFlag.existsIndicatingCrash(at: flagPath))
    }

    // MARK: - readPayload round-trip

    /// Write a sentinel with a specific mode, read it back, and
    /// confirm the mode round-trips. The `enabledAt` timestamp is
    /// stamped at write; we assert it lands close to `Date()` (no
    /// hard equality because `Date.init()` and JSON encode/decode
    /// can lose sub-microsecond precision).
    func testWriteAndReadPayloadRoundTripsMode() {
        let before = Date()
        ProxyActiveFlag.write(at: flagPath, mode: "Smart")
        let after = Date()

        guard let payload = ProxyActiveFlag.readPayload(at: flagPath) else {
            return XCTFail("readPayload returned nil after successful write")
        }
        XCTAssertEqual(payload.mode, "Smart")
        XCTAssertGreaterThanOrEqual(payload.enabledAt, before.addingTimeInterval(-1))
        XCTAssertLessThanOrEqual(payload.enabledAt, after.addingTimeInterval(1))
    }

    /// Each documented mode round-trips. Three modes the
    /// orchestrator can be in when it enables system proxy:
    /// `Smart`, `Global`, `Local`.
    func testRoundTripsAllDocumentedModes() {
        for mode in ["Smart", "Global", "Local"] {
            ProxyActiveFlag.write(at: flagPath, mode: mode)
            guard let payload = ProxyActiveFlag.readPayload(at: flagPath) else {
                return XCTFail("readPayload returned nil for mode=\(mode)")
            }
            XCTAssertEqual(payload.mode, mode)
            ProxyActiveFlag.clear(at: flagPath)
        }
    }

    /// `write` overwrites the previous sentinel atomically (the
    /// production code uses `Data.write(.atomic)`). A mode change
    /// from Smart → Global writes the new shape; the next read
    /// returns the new mode, not the old.
    func testWriteOverwritesExistingSentinel() {
        ProxyActiveFlag.write(at: flagPath, mode: "Smart")
        ProxyActiveFlag.write(at: flagPath, mode: "Global")
        let payload = ProxyActiveFlag.readPayload(at: flagPath)
        XCTAssertEqual(payload?.mode, "Global")
    }

    // MARK: - readPayload defensive cases

    /// Missing file → nil. First-launch case: no previous run
    /// wrote a sentinel, no payload to read.
    func testReadPayloadReturnsNilWhenMissing() {
        XCTAssertNil(ProxyActiveFlag.readPayload(at: flagPath))
    }

    /// Corrupt JSON → nil. A garbled sentinel (post-power-loss
    /// half-written, or hand-edited badly) doesn't crash the
    /// reader; the bootstrap path treats it the same as a missing
    /// sentinel and proceeds without forcing a disable.
    func testReadPayloadReturnsNilOnCorruptJSON() throws {
        try Data("not actually json {".utf8).write(to: flagPath)
        XCTAssertNil(ProxyActiveFlag.readPayload(at: flagPath))
        // Existence still reports true because the file is there
        // — orchestrator force-disables based on existence, NOT
        // payload readability. This pins that distinction.
        XCTAssertTrue(ProxyActiveFlag.existsIndicatingCrash(at: flagPath))
    }

    /// Wrong-version JSON (forward-compatibility) → nil. If a
    /// hypothetical v2 sentinel arrives at a v1 reader, the
    /// decode fails on the schema mismatch and the reader
    /// returns nil. Orchestrator still force-disables based on
    /// existence; the diagnostic payload just isn't available.
    func testReadPayloadReturnsNilForWrongSchema() throws {
        // Encode a different struct entirely. The Payload type
        // is `private`, so we just craft a JSON dict that won't
        // decode as Payload (missing the required `mode` field).
        try Data(#"{"version":1,"enabledAt":1234567890}"#.utf8).write(to: flagPath)
        XCTAssertNil(ProxyActiveFlag.readPayload(at: flagPath))
    }
}
