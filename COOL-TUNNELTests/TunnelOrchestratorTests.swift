// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
// COOL-TUNNELTests/TunnelOrchestratorTests.swift
//
// H3 plumbing regression coverage. The orchestrator's
// `hydratePasswordIfNeeded` private method delegates to the static
// `TunnelOrchestrator.hydratePassword(_:from:)` helper specifically
// so the H3 contract can be unit-tested without standing up the
// full orchestrator (which would require `CoreClient`,
// `SystemProxyController`, `FirewallProbe`, etc.).
//
// Pins:
//
//   - Credential-store read failure becomes
//     `OrchestratorError.credentialReadFailed`, NOT a passed-through
//     backend error.
//   - "No password set" (`""` from the store, per the
//     `CredentialStore` contract) flows through unchanged — the
//     validation gate downstream handles the empty-string case.
//   - An already-hydrated profile is a no-op regardless of store
//     state. The store is only consulted when the in-memory
//     password is empty (or whitespace).

import XCTest

@testable import Cool_Tunnel

final class TunnelOrchestratorTests: XCTestCase {

    // MARK: - Fixtures

    private func makeProfileStore() -> (ProfileStore, MockCredentialStore) {
        guard let defaults = UserDefaults(suiteName: UUID().uuidString) else {
            fatalError("could not create UserDefaults suite")
        }
        let credentials = MockCredentialStore()
        let store = ProfileStore(defaults: defaults, credentials: credentials)
        return (store, credentials)
    }

    private func emptyPasswordProfile(id: String = "p1") -> Profile {
        Profile(
            id: id,
            server: "proxy.example.com",
            username: "user",
            password: "",
            localPort: "1080"
        )
    }

    // MARK: - H3 — credential read failure becomes credentialReadFailed

    /// The H3 contract: a thrown `CredentialStore` error must
    /// reach the caller as `OrchestratorError.credentialReadFailed`,
    /// not the raw backend error. Pre-fix, the orchestrator
    /// collapsed the failure into the empty-string path and the
    /// user got "please enter a password" — wrong root cause.
    func testHydratePasswordThrowsCredentialReadFailedOnBackendError() throws {
        let (store, credentials) = makeProfileStore()
        credentials.failReadsWith(.backendLocked)

        var profile = emptyPasswordProfile()
        XCTAssertThrowsError(
            try TunnelOrchestrator.hydratePassword(&profile, from: store)
        ) { error in
            guard case OrchestratorError.credentialReadFailed(let reason) = error else {
                return XCTFail(
                    "expected OrchestratorError.credentialReadFailed, got \(type(of: error)): \(error)"
                )
            }
            // The reason carries the localized backend error so
            // operators reading the log can distinguish "locked" from
            // "decode failed" from "IO error".
            XCTAssertFalse(
                reason.isEmpty,
                "credentialReadFailed reason must surface the backend error")
        }
    }

    /// Belt-and-braces for the alternate failure modes the mock
    /// can simulate. All three must funnel into the same wrapper
    /// case — the orchestrator does NOT distinguish them at this
    /// layer.
    func testHydratePasswordWrapsEveryBackendErrorAsCredentialReadFailed() throws {
        let cases: [MockCredentialStore.InjectedError] = [
            .backendLocked,
            .backendIO("disk full"),
            .malformed,
        ]
        for injected in cases {
            let (store, credentials) = makeProfileStore()
            credentials.failReadsWith(injected)
            var profile = emptyPasswordProfile()
            XCTAssertThrowsError(
                try TunnelOrchestrator.hydratePassword(&profile, from: store)
            ) { error in
                guard case OrchestratorError.credentialReadFailed = error else {
                    return XCTFail(
                        "\(injected): expected credentialReadFailed, got \(error)")
                }
            }
        }
    }

    // MARK: - H3 — "not stored" is NOT an error

    /// Per the `CredentialStore` contract, item-not-found returns
    /// `""` rather than throwing. The orchestrator must preserve
    /// that distinction: an empty store value flows through, leaving
    /// the in-memory profile's empty password intact. The downstream
    /// validation gate is what surfaces "please enter a password."
    func testHydratePasswordTreatsEmptyAsNoPasswordSet() throws {
        let (store, _) = makeProfileStore()
        var profile = emptyPasswordProfile()
        XCTAssertNoThrow(try TunnelOrchestrator.hydratePassword(&profile, from: store))
        XCTAssertEqual(profile.password, "", "empty store value must leave password empty")
    }

    // MARK: - hydration — hits the store only when the password is empty

    /// An already-hydrated profile must be a no-op. The store
    /// should not even be consulted — this is what keeps the
    /// orchestrator from accidentally re-prompting the keychain on
    /// every Start when the password is already in hand.
    func testHydratePasswordIsNoOpWhenPasswordAlreadyPresent() throws {
        let (store, credentials) = makeProfileStore()
        // Configure the store to throw if anyone reads from it. The
        // test passes only if `hydratePassword` short-circuits before
        // the read.
        credentials.failReadsWith(.backendLocked)

        var profile = emptyPasswordProfile()
        profile.password = "already-set"
        XCTAssertNoThrow(try TunnelOrchestrator.hydratePassword(&profile, from: store))
        XCTAssertEqual(profile.password, "already-set", "in-memory password must not be touched")
    }

    /// Whitespace-only passwords count as empty (the orchestrator
    /// trims before deciding whether to hydrate). Pre-trim path was
    /// silently leaking "user typed three spaces" as a valid
    /// password until v0.1.7-ish.
    func testHydratePasswordTreatsWhitespacePasswordAsEmpty() throws {
        let (store, credentials) = makeProfileStore()
        try credentials.setPassword("real-pwd", forProfileID: "p1")

        var profile = emptyPasswordProfile()
        profile.password = "   "
        XCTAssertNoThrow(try TunnelOrchestrator.hydratePassword(&profile, from: store))
        XCTAssertEqual(
            profile.password, "real-pwd",
            "whitespace-only password must trigger hydration from the store")
    }

    /// When the store returns a value AND the profile's password
    /// is empty, hydration fills it in.
    func testHydratePasswordFillsFromStoreWhenPresent() throws {
        let (store, credentials) = makeProfileStore()
        try credentials.setPassword("from-store", forProfileID: "p1")

        var profile = emptyPasswordProfile()
        XCTAssertNoThrow(try TunnelOrchestrator.hydratePassword(&profile, from: store))
        XCTAssertEqual(profile.password, "from-store")
    }
}
