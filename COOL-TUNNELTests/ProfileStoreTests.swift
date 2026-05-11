// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
// COOL-TUNNELTests/ProfileStoreTests.swift
//
// Regression coverage for the H2 + H3 + M1 fixes that landed in
// v2.0.38 and v2.0.39. Each test names the specific failure mode
// the fix guards against so a future regression has a clear
// signal in the test log.

import XCTest

@testable import Cool_Tunnel

final class ProfileStoreTests: XCTestCase {

    // MARK: - Fixtures

    /// Builds a fresh `ProfileStore` against an isolated `UserDefaults`
    /// suite (so test ordering can't leak state) and a fresh mock
    /// `CredentialStore`. The credential mock is returned alongside so
    /// individual tests can drive its failure injection knobs.
    private func makeStore(
        suiteName: String = UUID().uuidString
    )
        -> (store: ProfileStore, defaults: UserDefaults, credentials: MockCredentialStore)
    {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("could not create UserDefaults suite \(suiteName)")
        }
        // Belt-and-braces clean. `UserDefaults(suiteName:)` should give
        // us a blank suite, but on Apple Silicon test runs we've seen
        // leftover state from a previous crashed test occasionally
        // survive — explicit wipe keeps each test deterministic.
        for key in defaults.dictionaryRepresentation().keys {
            defaults.removeObject(forKey: key)
        }
        let credentials = MockCredentialStore()
        let store = ProfileStore(defaults: defaults, credentials: credentials)
        return (store, defaults, credentials)
    }

    /// Encodes a profile blob the way `ProfileStore.persistStripped`
    /// would, so `loadProfiles` reads it back via the same path a
    /// real-app launch would take. Used by the H2 migration tests
    /// to plant a "legacy plaintext password" in UserDefaults.
    private func planRawProfilesBlob(_ profiles: [Profile], in defaults: UserDefaults) throws {
        let data = try JSONEncoder().encode(profiles)
        defaults.set(data, forKey: "profiles")
    }

    private func legacyProfile(id: String = "p1", password: String) -> Profile {
        Profile(
            id: id,
            server: "proxy.example.com",
            username: "user",
            password: password,
            localPort: "1080"
        )
    }

    // MARK: - H2 regression — migration write failure must not strip

    /// The fix: when the credential-store migration write fails,
    /// `loadProfiles` keeps the legacy password in UserDefaults
    /// instead of stripping it. Pre-fix, the password was lost from
    /// both backends after one failed launch.
    func testLoadKeepsLegacyPasswordWhenCredentialMigrationFails() throws {
        let (store, defaults, credentials) = makeStore()

        // Plant a profile with a legacy plaintext password.
        try planRawProfilesBlob([legacyProfile(password: "hunter2")], in: defaults)

        // Make the credential store reject the promotion write.
        credentials.failWritesWith(.backendLocked)

        let loaded = store.loadProfiles()

        // The in-memory profile still carries the password so the
        // caller can use it.
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.password, "hunter2")

        // And — the part that broke before H2 — the UserDefaults blob
        // still contains the legacy password. Decode it back to assert.
        guard let raw = defaults.data(forKey: "profiles") else {
            return XCTFail("profiles key disappeared")
        }
        let persisted = try JSONDecoder().decode([Profile].self, from: raw)
        XCTAssertEqual(
            persisted.first?.password, "hunter2",
            "legacy password must persist in UserDefaults when migration fails")
    }

    /// The successful-migration counterpart: when the credential
    /// store write succeeds, the password DOES get stripped from
    /// UserDefaults. Otherwise we'd leave the plaintext sitting in
    /// .plist forever.
    func testLoadStripsLegacyPasswordOnSuccessfulMigration() throws {
        let (store, defaults, credentials) = makeStore()
        try planRawProfilesBlob([legacyProfile(password: "hunter2")], in: defaults)

        // No injected error — write succeeds.
        let loaded = store.loadProfiles()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(
            credentials.snapshot()["p1"], "hunter2",
            "credential store should hold the promoted password")

        guard let raw = defaults.data(forKey: "profiles") else {
            return XCTFail("profiles key disappeared")
        }
        let persisted = try JSONDecoder().decode([Profile].self, from: raw)
        XCTAssertEqual(
            persisted.first?.password, "",
            "successful migration must strip the legacy password from UserDefaults")
    }

    // MARK: - H2 regression — save() write failure must not strip

    func testSavePreservesPasswordOnCredentialWriteFailure() throws {
        let (store, defaults, credentials) = makeStore()
        let profile = legacyProfile(password: "newpwd")

        // Configure the credential store to fail.
        credentials.failWritesWith(.backendLocked)
        store.save(profiles: [profile])

        // The UserDefaults blob must STILL carry the password, because
        // the credential store didn't accept it and we'd otherwise have
        // nowhere to recover it from.
        guard let raw = defaults.data(forKey: "profiles") else {
            return XCTFail("profiles key disappeared")
        }
        let persisted = try JSONDecoder().decode([Profile].self, from: raw)
        XCTAssertEqual(
            persisted.first?.password, "newpwd",
            "credential-write failure must not strip the password from UserDefaults")
    }

    func testSaveStripsPasswordWhenCredentialWriteSucceeds() throws {
        let (store, defaults, credentials) = makeStore()
        let profile = legacyProfile(password: "newpwd")
        store.save(profiles: [profile])

        XCTAssertEqual(credentials.snapshot()["p1"], "newpwd")
        guard let raw = defaults.data(forKey: "profiles") else {
            return XCTFail("profiles key disappeared")
        }
        let persisted = try JSONDecoder().decode([Profile].self, from: raw)
        XCTAssertEqual(persisted.first?.password, "")
    }

    // MARK: - H3 regression — password() must throw, not collapse to ""

    /// The fix: `password(forProfileID:)` propagates the
    /// `CredentialStore` error instead of returning `""`. Pre-fix the
    /// orchestrator couldn't tell "keychain locked" from "no
    /// password set" and prompted the user to re-enter a password
    /// that was already there.
    func testPasswordReadPropagatesBackendError() throws {
        let (store, _, credentials) = makeStore()
        credentials.failReadsWith(.backendLocked)

        XCTAssertThrowsError(try store.password(forProfileID: "p1")) { error in
            guard let injected = error as? MockCredentialStore.InjectedError else {
                return XCTFail("expected InjectedError, got \(type(of: error)): \(error)")
            }
            XCTAssertEqual(injected, .backendLocked)
        }
    }

    /// Item-not-found is NOT an error per the `CredentialStore`
    /// contract — the backend returns `""`, and `password()` faithfully
    /// returns it without throwing. The orchestrator's empty-string
    /// branch covers "user never set a password."
    func testPasswordReadReturnsEmptyWhenNotStored() throws {
        let (store, _, _) = makeStore()
        XCTAssertEqual(try store.password(forProfileID: "p-never-set"), "")
    }
}
