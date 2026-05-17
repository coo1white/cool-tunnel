// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
// COOL-TUNNELTests/ProfileStoreTests.swift
//
// Regression coverage for the H2 + H3 + M1 fixes that landed in
// v2.0.38 and v2.0.39. Each test names the specific failure mode
// the fix guards against so a future regression has a clear
// signal in the test log.
//
// **v3.0.0 (sub-phase F):** call sites rename to the new
// `uuid` / `setUUID` / `deleteUUID` API. Test names use
// "credential" / "uuid" interchangeably for the secret — the
// regression semantics carry forward from v2.x verbatim.

import XCTest

@testable import Cool_Tunnel

final class ProfileStoreTests: XCTestCase {

    // MARK: - Fixtures

    /// Builds a fresh `ProfileStore` against an isolated `UserDefaults`
    /// suite (so test ordering can't leak state) and a fresh mock
    /// `CredentialStore`. The credential mock is returned alongside so
    /// individual tests can drive its failure injection knobs. The
    /// `suiteName` defaults to a fresh UUID per call, so suite names
    /// never collide between tests and the resulting suite is
    /// guaranteed empty.
    private func makeStore(
        suiteName: String = UUID().uuidString
    )
        -> (store: ProfileStore, defaults: UserDefaults, credentials: MockCredentialStore)
    {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("could not create UserDefaults suite \(suiteName)")
        }
        let credentials = MockCredentialStore()
        let store = ProfileStore(defaults: defaults, credentials: credentials)
        return (store, defaults, credentials)
    }

    /// Encodes a profile blob the way `ProfileStore.persistStripped`
    /// would, so `loadProfiles` reads it back via the same path a
    /// real-app launch would take. Used by the H2 migration tests
    /// to plant a "legacy plaintext credential" in UserDefaults.
    private func plantRawProfilesBlob(_ profiles: [Profile], in defaults: UserDefaults) throws {
        let data = try JSONEncoder().encode(profiles)
        defaults.set(data, forKey: "profiles")
    }

    private func legacyProfile(id: String = "p1", uuid: String) -> Profile {
        Profile(
            id: id,
            server: "proxy.example.com",
            username: "user",
            uuid: uuid,
            reality: .empty,
            localPort: "1080"
        )
    }

    // MARK: - H2 regression — migration write failure must not strip

    /// The fix: when the credential-store migration write fails,
    /// `loadProfiles` keeps the legacy credential in UserDefaults
    /// instead of stripping it. Pre-fix, the credential was lost
    /// from both backends after one failed launch.
    func testLoadKeepsLegacyCredentialWhenCredentialMigrationFails() throws {
        let (store, defaults, credentials) = makeStore()

        // Plant a profile with a legacy plaintext credential.
        try plantRawProfilesBlob([legacyProfile(uuid: "hunter2")], in: defaults)

        // Make the credential store reject the promotion write.
        credentials.failWritesWith(.backendLocked)

        let loaded = store.loadProfiles()

        // The in-memory profile still carries the credential so the
        // caller can use it.
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.uuid, "hunter2")

        // And — the part that broke before H2 — the UserDefaults blob
        // still contains the legacy credential. Decode it back to assert.
        guard let raw = defaults.data(forKey: "profiles") else {
            return XCTFail("profiles key disappeared")
        }
        let persisted = try JSONDecoder().decode([Profile].self, from: raw)
        XCTAssertEqual(
            persisted.first?.uuid, "hunter2",
            "legacy credential must persist in UserDefaults when migration fails")
    }

    /// The successful-migration counterpart: when the credential
    /// store write succeeds, the credential DOES get stripped from
    /// UserDefaults. Otherwise we'd leave the plaintext sitting in
    /// .plist forever.
    func testLoadStripsLegacyCredentialOnSuccessfulMigration() throws {
        let (store, defaults, credentials) = makeStore()
        try plantRawProfilesBlob([legacyProfile(uuid: "hunter2")], in: defaults)

        // No injected error — write succeeds.
        let loaded = store.loadProfiles()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(
            credentials.snapshot()["p1"], "hunter2",
            "credential store should hold the promoted UUID")

        guard let raw = defaults.data(forKey: "profiles") else {
            return XCTFail("profiles key disappeared")
        }
        let persisted = try JSONDecoder().decode([Profile].self, from: raw)
        XCTAssertEqual(
            persisted.first?.uuid, "",
            "successful migration must strip the legacy credential from UserDefaults")
    }

    // MARK: - H2 regression — save() write failure must not strip

    func testSavePreservesCredentialOnCredentialWriteFailure() throws {
        let (store, defaults, credentials) = makeStore()
        let profile = legacyProfile(uuid: "newpwd")

        // Configure the credential store to fail.
        credentials.failWritesWith(.backendLocked)
        store.save(profiles: [profile])

        // The UserDefaults blob must STILL carry the credential, because
        // the credential store didn't accept it and we'd otherwise have
        // nowhere to recover it from.
        guard let raw = defaults.data(forKey: "profiles") else {
            return XCTFail("profiles key disappeared")
        }
        let persisted = try JSONDecoder().decode([Profile].self, from: raw)
        XCTAssertEqual(
            persisted.first?.uuid, "newpwd",
            "credential-write failure must not strip the credential from UserDefaults")
    }

    func testSaveStripsCredentialWhenCredentialWriteSucceeds() throws {
        let (store, defaults, credentials) = makeStore()
        let profile = legacyProfile(uuid: "newpwd")
        store.save(profiles: [profile])

        XCTAssertEqual(credentials.snapshot()["p1"], "newpwd")
        guard let raw = defaults.data(forKey: "profiles") else {
            return XCTFail("profiles key disappeared")
        }
        let persisted = try JSONDecoder().decode([Profile].self, from: raw)
        XCTAssertEqual(persisted.first?.uuid, "")
    }

    // MARK: - H3 regression — uuid() must throw, not collapse to ""

    /// The fix: `uuid(forProfileID:)` propagates the
    /// `CredentialStore` error instead of returning `""`. Pre-fix the
    /// orchestrator couldn't tell "keychain locked" from "no
    /// credential set" and prompted the user to re-enter a credential
    /// that was already there.
    func testCredentialReadPropagatesBackendError() throws {
        let (store, _, credentials) = makeStore()
        credentials.failReadsWith(.backendLocked)

        XCTAssertThrowsError(try store.uuid(forProfileID: "p1")) { error in
            guard let injected = error as? MockCredentialStore.InjectedError else {
                return XCTFail("expected InjectedError, got \(type(of: error)): \(error)")
            }
            XCTAssertEqual(injected, .backendLocked)
        }
    }

    /// Item-not-found is NOT an error per the `CredentialStore`
    /// contract — the backend returns `""`, and `uuid()` faithfully
    /// returns it without throwing. The orchestrator's empty-string
    /// branch covers "user never set a credential."
    func testCredentialReadReturnsEmptyWhenNotStored() throws {
        let (store, _, _) = makeStore()
        XCTAssertEqual(try store.uuid(forProfileID: "p-never-set"), "")
    }

    // MARK: - M1 regression — deleteUUID swallows backend failure

    /// M1: `ProfileStore.deleteUUID(forProfileID:)` is the
    /// `void`-returning public API the orchestrator calls when the
    /// user removes a profile. The credential-store delete is
    /// best-effort — a backend failure must NOT propagate (the
    /// caller has already removed the profile id from the in-memory
    /// list, so throwing here would split the UI from the persisted
    /// state). The M1 sweep added the `do/catch + Logger.warning`
    /// shape; this test pins that the no-throw contract holds.
    func testDeleteCredentialSwallowsCredentialStoreFailure() throws {
        let (store, _, credentials) = makeStore()
        try credentials.setUUID("v", forProfileID: "p1")
        credentials.failDeletesWith(.backendIO("read-only fs"))

        // Must not throw — the H2/M1 contract for the void-returning
        // delete API. The os_log warning is emitted as a side effect;
        // we assert the observable behavior (no throw, void return).
        XCTAssertNoThrow(store.deleteUUID(forProfileID: "p1"))
    }

    /// Sanity: when the credential store accepts the delete, the
    /// entry actually goes away. Locks in the happy path against a
    /// regression where the do/catch shape might accidentally swallow
    /// the successful call.
    func testDeleteCredentialRemovesEntryOnSuccess() throws {
        let (store, _, credentials) = makeStore()
        try credentials.setUUID("v", forProfileID: "p1")
        XCTAssertEqual(credentials.snapshot()["p1"], "v", "precondition: seeded")

        store.deleteUUID(forProfileID: "p1")
        XCTAssertNil(credentials.snapshot()["p1"], "credential entry must be gone")
    }
}
