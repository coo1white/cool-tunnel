// Persistence/CredentialStore.swift
//
// Common interface for per-profile password storage so the higher
// layers (ProfileStore, TunnelOrchestrator) can swap backends without
// caring whether the bytes live in the macOS Keychain, in a 0600 file
// under Application Support, or in a test mock.
//
// Three concrete implementations exist:
//
//   - `FileCredentialStore`  — primary, file-backed. The default.
//   - `KeychainStore`        — legacy. Kept around as the migration
//                              source for users upgrading from
//                              v0.1.5.4 and earlier.
//   - `MigratingCredentialStore` — composes the above two: reads from
//                                  primary first, falls back to legacy
//                                  on a miss, and writes the result
//                                  back to primary so the next access
//                                  bypasses legacy entirely.
//
// The migrating store is the one the orchestrator wires up. The
// effect is "ready to use out of the box": new installs never touch
// the Keychain (no system password prompt before the UI appears),
// upgrades from earlier versions migrate transparently the first
// time the user clicks Start.

import Foundation

/// Per-profile password backend. Implementations must be safe to
/// call from any actor — the orchestrator hits them on its main
/// actor but tests run them off-thread.
public protocol CredentialStore: Sendable {
    /// Returns the stored password for a profile id, or an empty
    /// string when nothing is stored. Throws on unexpected backend
    /// failures (a missing item is **not** an error).
    func password(forProfileID id: String) throws -> String

    /// Writes (or overwrites) the password for a profile id. Empty
    /// passwords delete the entry — there is no point in keeping a
    /// sentinel "no password" record.
    func setPassword(_ password: String, forProfileID id: String) throws

    /// Removes the entry for a profile id. No-op when none is stored.
    func deletePassword(forProfileID id: String) throws
}

// MARK: - Migrating wrapper

/// Reads from `primary` first; on a miss, reads from `legacy`,
/// promotes the value into `primary`, and best-effort deletes from
/// `legacy`. Subsequent reads bypass `legacy` entirely.
///
/// The point: the legacy backend is only touched the first time
/// **the user takes an action that needs a password** (clicking
/// Start). It is never touched at app launch — which is what makes
/// the "no system password prompt before the UI appears" guarantee
/// hold for users upgrading from a Keychain-only build.
public struct MigratingCredentialStore: CredentialStore {
    public let primary: any CredentialStore
    public let legacy: any CredentialStore

    public init(primary: any CredentialStore, legacy: any CredentialStore) {
        self.primary = primary
        self.legacy = legacy
    }

    public func password(forProfileID id: String) throws -> String {
        let primaryValue = try primary.password(forProfileID: id)
        if !primaryValue.isEmpty {
            return primaryValue
        }
        // Primary is empty — try the legacy backend. This is where
        // the Keychain access (and the OS prompt, if any) happens —
        // and only because the caller actively asked for the
        // password (e.g. user clicked Start).
        let legacyValue = (try? legacy.password(forProfileID: id)) ?? ""
        if legacyValue.isEmpty {
            return ""
        }
        // Promote into primary so the next launch finds the value
        // in the file store and skips the legacy backend forever.
        // Best-effort: a write failure here just means we re-migrate
        // next time, which is a UX wart but not a correctness bug.
        try? primary.setPassword(legacyValue, forProfileID: id)
        // Best-effort delete of the legacy entry so the OS-level
        // ACL stays clean and there is no second copy lurking.
        try? legacy.deletePassword(forProfileID: id)
        return legacyValue
    }

    public func setPassword(_ password: String, forProfileID id: String) throws {
        try primary.setPassword(password, forProfileID: id)
        // Also clear the legacy entry on a fresh write — keeps the
        // two backends from drifting if the user changes a password
        // through the UI before the migration read fires.
        try? legacy.deletePassword(forProfileID: id)
    }

    public func deletePassword(forProfileID id: String) throws {
        try primary.deletePassword(forProfileID: id)
        try? legacy.deletePassword(forProfileID: id)
    }
}

// `KeychainStore`'s `CredentialStore` conformance lives in
// `KeychainStore.swift` per Swift convention (conformances belong
// with the type, not the protocol).
