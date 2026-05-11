// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
// COOL-TUNNELTests/MockCredentialStore.swift

import Foundation

@testable import Cool_Tunnel

/// In-memory, configurable `CredentialStore` for unit tests.
///
/// Mirrors `FileCredentialStore` semantics (empty string == not stored,
/// throw on backend failure) but exposes injectable failure behavior
/// for the H2/H3/M1 regression tests.
public final class MockCredentialStore: CredentialStore, @unchecked Sendable {
    /// Backend failure modes the mock can be configured to throw.
    public enum InjectedError: Error, Equatable {
        case backendLocked
        case backendIO(String)
        case malformed
    }

    private let lock = NSLock()
    private var storage: [String: String] = [:]
    private var readError: InjectedError?
    private var writeError: InjectedError?
    private var deleteError: InjectedError?

    public init() {}

    // MARK: - Test-only API

    /// Configure the next (and subsequent, until cleared) `password`
    /// call to throw the given error.
    public func failReadsWith(_ error: InjectedError?) {
        lock.lock()
        defer { lock.unlock() }
        readError = error
    }

    public func failWritesWith(_ error: InjectedError?) {
        lock.lock()
        defer { lock.unlock() }
        writeError = error
    }

    public func failDeletesWith(_ error: InjectedError?) {
        lock.lock()
        defer { lock.unlock() }
        deleteError = error
    }

    /// Direct write that bypasses the configured `writeError`. Useful
    /// for seeding a "legacy" backend with a value before the
    /// migrating wrapper reads it.
    public func seed(password: String, forProfileID id: String) {
        lock.lock()
        defer { lock.unlock() }
        storage[id] = password
    }

    public func snapshot() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    // MARK: - CredentialStore conformance

    public func password(forProfileID id: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        if let injected = readError {
            throw injected
        }
        return storage[id] ?? ""
    }

    public func setPassword(_ password: String, forProfileID id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if let injected = writeError {
            throw injected
        }
        if password.isEmpty {
            storage.removeValue(forKey: id)
        } else {
            storage[id] = password
        }
    }

    public func deletePassword(forProfileID id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if let injected = deleteError {
            throw injected
        }
        storage.removeValue(forKey: id)
    }
}
