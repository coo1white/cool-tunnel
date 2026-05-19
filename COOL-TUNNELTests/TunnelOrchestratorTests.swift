// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
// COOL-TUNNELTests/TunnelOrchestratorTests.swift
//
// H3 plumbing regression coverage. The orchestrator's
// `hydrateUUIDIfNeeded` private method delegates to the static
// `TunnelOrchestrator.hydrateUUID(_:from:)` helper specifically
// so the H3 contract can be unit-tested without standing up the
// full orchestrator (which would require `CoreClient`,
// `SystemProxyController`, `FirewallProbe`, etc.).
//
// **v3.0.0 (sub-phase F):** call sites rename to the new
// `uuid` / `setUUID` API. Test names use "credential" / "uuid"
// interchangeably; the H3 / H2 / M1 semantics carry forward
// from v2.x verbatim.

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

    private func emptyCredentialProfile(id: String = "p1") -> Profile {
        Profile(
            id: id,
            server: "proxy.example.com",
            username: "user",
            uuid: "",
            reality: .empty,
            localPort: "1080"
        )
    }

    // MARK: - H3 — credential read failure becomes credentialReadFailed

    /// The H3 contract: a thrown `CredentialStore` error must
    /// reach the caller as `OrchestratorError.credentialReadFailed`,
    /// not the raw backend error. Pre-fix, the orchestrator
    /// collapsed the failure into the empty-string path and the
    /// user got "please enter a credential" — wrong root cause.
    func testHydrateUUIDThrowsCredentialReadFailedOnBackendError() throws {
        let (store, credentials) = makeProfileStore()
        credentials.failReadsWith(.backendLocked)

        var profile = emptyCredentialProfile()
        XCTAssertThrowsError(
            try TunnelOrchestrator.hydrateUUID(&profile, from: store)
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
    func testHydrateUUIDWrapsEveryBackendErrorAsCredentialReadFailed() throws {
        let cases: [MockCredentialStore.InjectedError] = [
            .backendLocked,
            .backendIO("disk full"),
            .malformed,
        ]
        for injected in cases {
            let (store, credentials) = makeProfileStore()
            credentials.failReadsWith(injected)
            var profile = emptyCredentialProfile()
            XCTAssertThrowsError(
                try TunnelOrchestrator.hydrateUUID(&profile, from: store)
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
    /// the in-memory profile's empty credential intact. The downstream
    /// validation gate is what surfaces "please enter a credential."
    func testHydrateUUIDTreatsEmptyAsNoCredentialSet() throws {
        let (store, _) = makeProfileStore()
        var profile = emptyCredentialProfile()
        XCTAssertNoThrow(try TunnelOrchestrator.hydrateUUID(&profile, from: store))
        XCTAssertEqual(profile.uuid, "", "empty store value must leave credential empty")
    }

    // MARK: - hydration — hits the store only when the credential is empty

    /// An already-hydrated profile must be a no-op. The store
    /// should not even be consulted — this is what keeps the
    /// orchestrator from accidentally re-prompting the keychain on
    /// every Start when the credential is already in hand.
    func testHydrateUUIDIsNoOpWhenCredentialAlreadyPresent() throws {
        let (store, credentials) = makeProfileStore()
        // Configure the store to throw if anyone reads from it. The
        // test passes only if `hydrateUUID` short-circuits before
        // the read.
        credentials.failReadsWith(.backendLocked)

        var profile = emptyCredentialProfile()
        profile.uuid = "already-set"
        XCTAssertNoThrow(try TunnelOrchestrator.hydrateUUID(&profile, from: store))
        XCTAssertEqual(profile.uuid, "already-set", "in-memory credential must not be touched")
    }

    /// Whitespace-only credentials count as empty (the orchestrator
    /// trims before deciding whether to hydrate). Pre-trim path was
    /// silently leaking "user typed three spaces" as a valid
    /// credential until v0.1.7-ish.
    func testHydrateUUIDTreatsWhitespaceCredentialAsEmpty() throws {
        let (store, credentials) = makeProfileStore()
        try credentials.setUUID("real-uuid", forProfileID: "p1")

        var profile = emptyCredentialProfile()
        profile.uuid = "   "
        XCTAssertNoThrow(try TunnelOrchestrator.hydrateUUID(&profile, from: store))
        XCTAssertEqual(
            profile.uuid, "real-uuid",
            "whitespace-only credential must trigger hydration from the store")
    }

    /// When the store returns a value AND the profile's credential
    /// is empty, hydration fills it in.
    func testHydrateUUIDFillsFromStoreWhenPresent() throws {
        let (store, credentials) = makeProfileStore()
        try credentials.setUUID("from-store", forProfileID: "p1")

        var profile = emptyCredentialProfile()
        XCTAssertNoThrow(try TunnelOrchestrator.hydrateUUID(&profile, from: store))
        XCTAssertEqual(profile.uuid, "from-store")
    }

    // MARK: - PAC generation

    func testSmartPacOnlyRunsPrivateRangeChecksOnIPv4Literals() {
        let pac = TunnelOrchestrator.generatePacJavaScript(
            directDomains: ["cn"],
            port: 1080
        )

        XCTAssertTrue(pac.contains("function isIPv4Literal(value)"))
        XCTAssertTrue(pac.contains("if (isIPv4Literal(host)) {"))
        XCTAssertTrue(pac.contains("isInNet(host, \"10.0.0.0\", \"255.0.0.0\")"))

        guard let literalGate = pac.range(of: "if (isIPv4Literal(host)) {"),
            let firstPrivateCheck = pac.range(of: "isInNet(host, \"10.0.0.0\"")
        else {
            return XCTFail("PAC did not contain the expected IPv4 literal guard")
        }
        XCTAssertLessThan(
            literalGate.lowerBound,
            firstPrivateCheck.lowerBound,
            "PAC must not call isInNet(host, ...) before proving host is an IPv4 literal; PAC engines may DNS-resolve hostnames there."
        )
    }

    func testSmartPacEscapesUserControlledDirectDomains() {
        let pac = TunnelOrchestrator.generatePacJavaScript(
            directDomains: ["good.cn", #"evil.com"; return "DIRECT"#],
            port: 1080
        )

        XCTAssertTrue(pac.contains(#""good.cn""#))
        XCTAssertTrue(pac.contains(#""evil.com\"; return \"DIRECT""#))
        XCTAssertFalse(
            pac.contains(#""evil.com"; return "DIRECT""#),
            "User-controlled direct domains must not be able to terminate the PAC string literal."
        )
    }
}
