// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
// COOL-TUNNELTests/MigratingCredentialStoreTests.swift
//
// Covers the H2 "don't lose credentials on partial-success" invariant
// that lives inside `MigratingCredentialStore`, plus the M1 logging
// behavior on legacy-cleanup failures.
//
// **v3.0.0 (sub-phase F):** call sites rename to the new
// `uuid` / `setUUID` / `deleteUUID` API; semantics are unchanged.

import XCTest

@testable import Cool_Tunnel

final class MigratingCredentialStoreTests: XCTestCase {

    private func makePair() -> (
        migrating: MigratingCredentialStore,
        primary: MockCredentialStore,
        legacy: MockCredentialStore
    ) {
        let primary = MockCredentialStore()
        let legacy = MockCredentialStore()
        let migrating = MigratingCredentialStore(primary: primary, legacy: legacy)
        return (migrating, primary, legacy)
    }

    // MARK: - Read path

    func testReadPrefersPrimaryWhenPresent() throws {
        let (migrating, primary, legacy) = makePair()
        try primary.setUUID("p-value", forProfileID: "p1")
        legacy.seed(uuid: "legacy-value", forProfileID: "p1")

        XCTAssertEqual(try migrating.uuid(forProfileID: "p1"), "p-value")
        // Legacy untouched on a hit.
        XCTAssertEqual(legacy.snapshot()["p1"], "legacy-value")
    }

    func testReadFallsBackToLegacyAndPromotes() throws {
        let (migrating, primary, legacy) = makePair()
        legacy.seed(uuid: "legacy-value", forProfileID: "p1")

        XCTAssertEqual(try migrating.uuid(forProfileID: "p1"), "legacy-value")
        XCTAssertEqual(
            primary.snapshot()["p1"], "legacy-value",
            "successful promotion writes the legacy value into primary")
        XCTAssertNil(
            legacy.snapshot()["p1"],
            "legacy entry is cleaned up after successful promotion")
    }

    /// H2 invariant: if primary write fails, legacy is NOT deleted.
    /// Pre-fix, both `try?` calls ran independently — a failed primary
    /// followed by a successful legacy delete lost the credential.
    func testReadKeepsLegacyWhenPromotionFails() throws {
        let (migrating, primary, legacy) = makePair()
        legacy.seed(uuid: "legacy-value", forProfileID: "p1")
        primary.failWritesWith(.backendLocked)

        // The caller still gets the value (worst case: one more
        // keychain prompt on next launch, not data loss).
        XCTAssertEqual(try migrating.uuid(forProfileID: "p1"), "legacy-value")
        XCTAssertEqual(
            legacy.snapshot()["p1"], "legacy-value",
            "legacy must remain when promotion fails")
        XCTAssertNil(primary.snapshot()["p1"])
    }

    /// M1 sweep behavior: the legacy-cleanup delete is best-effort.
    /// A failed delete must NOT prevent the read from succeeding —
    /// the caller already has the value via primary.
    func testReadSucceedsWhenLegacyCleanupFails() throws {
        let (migrating, _, legacy) = makePair()
        legacy.seed(uuid: "legacy-value", forProfileID: "p1")
        legacy.failDeletesWith(.backendIO("disk full"))

        // Should not throw; the cleanup failure is logged but doesn't
        // bubble. (We can't observe the os_log line from here; the
        // assertion is on observable behavior — return value + state.)
        XCTAssertEqual(try migrating.uuid(forProfileID: "p1"), "legacy-value")
    }

    // MARK: - Write path

    func testSetUUIDWritesPrimaryAndClearsLegacy() throws {
        let (migrating, primary, legacy) = makePair()
        legacy.seed(uuid: "stale", forProfileID: "p1")

        try migrating.setUUID("fresh", forProfileID: "p1")

        XCTAssertEqual(primary.snapshot()["p1"], "fresh")
        XCTAssertNil(
            legacy.snapshot()["p1"],
            "legacy entry must be cleared on a fresh write")
    }

    /// Primary write throws ⇒ propagate to caller. The legacy cleanup
    /// runs only AFTER a successful primary write, so we never reach
    /// the failure-in-cleanup branch here.
    func testSetUUIDPropagatesPrimaryWriteFailure() throws {
        let (migrating, primary, legacy) = makePair()
        primary.failWritesWith(.backendIO("read-only fs"))
        legacy.seed(uuid: "stale", forProfileID: "p1")

        XCTAssertThrowsError(try migrating.setUUID("fresh", forProfileID: "p1"))
        XCTAssertEqual(
            legacy.snapshot()["p1"], "stale",
            "legacy must remain when primary write fails")
        XCTAssertNil(primary.snapshot()["p1"])
    }

    /// M1: legacy-cleanup failure after a successful primary write
    /// does NOT bubble — the primary has the new value, the cleanup
    /// is best-effort. The user observes a successful save.
    func testSetUUIDSucceedsWhenLegacyCleanupFails() throws {
        let (migrating, primary, legacy) = makePair()
        legacy.seed(uuid: "stale", forProfileID: "p1")
        legacy.failDeletesWith(.backendIO("disk full"))

        XCTAssertNoThrow(try migrating.setUUID("fresh", forProfileID: "p1"))
        XCTAssertEqual(primary.snapshot()["p1"], "fresh")
        // Legacy still has the stale value; not ideal but not data
        // loss — primary is the source of truth from here.
        XCTAssertEqual(legacy.snapshot()["p1"], "stale")
    }

    // MARK: - Delete path

    func testDeleteUUIDRemovesFromBoth() throws {
        let (migrating, primary, legacy) = makePair()
        try primary.setUUID("v", forProfileID: "p1")
        legacy.seed(uuid: "v", forProfileID: "p1")

        try migrating.deleteUUID(forProfileID: "p1")

        XCTAssertNil(primary.snapshot()["p1"])
        XCTAssertNil(legacy.snapshot()["p1"])
    }

    func testDeleteUUIDPropagatesPrimaryFailure() throws {
        let (migrating, primary, legacy) = makePair()
        try primary.setUUID("v", forProfileID: "p1")
        legacy.seed(uuid: "v", forProfileID: "p1")
        primary.failDeletesWith(.backendIO("read-only fs"))

        XCTAssertThrowsError(try migrating.deleteUUID(forProfileID: "p1"))
        XCTAssertEqual(
            primary.snapshot()["p1"], "v",
            "primary entry remains when its delete fails")
    }

    /// M1: legacy-cleanup failure during delete is logged, not raised.
    /// User-facing semantic: "I deleted my profile" ⇒ primary is gone,
    /// regardless of whether the legacy keychain happened to cooperate.
    func testDeleteUUIDSucceedsWhenLegacyCleanupFails() throws {
        let (migrating, primary, legacy) = makePair()
        try primary.setUUID("v", forProfileID: "p1")
        legacy.seed(uuid: "v", forProfileID: "p1")
        legacy.failDeletesWith(.backendIO("disk full"))

        XCTAssertNoThrow(try migrating.deleteUUID(forProfileID: "p1"))
        XCTAssertNil(primary.snapshot()["p1"])
    }
}
