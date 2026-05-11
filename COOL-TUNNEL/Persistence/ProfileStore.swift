// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
// Persistence/ProfileStore.swift
//
// Persists the user's saved `Profile`s and the currently selected
// profile id. Identifier, server, username, and local port live in
// `UserDefaults` (low-sensitivity); passwords live in the configured
// [`CredentialStore`] (file-backed by default; Keychain available
// behind a migrating wrapper for upgrades).
//
// **Critical invariant for v0.1.5.5:** `loadProfiles()` does NOT
// touch the credential store. Profiles are returned with empty
// passwords; the orchestrator hydrates the password on demand from
// `start(mode:)`. This is what guarantees the app never triggers a
// system-password / "approve keychain access" prompt before the UI
// appears — for upgraders, the only place a Keychain access can
// fire is the migration path inside [`MigratingCredentialStore`],
// which only runs on a user-initiated Start.

import Foundation
import os

/// Stores profiles + selection. Marked `@unchecked Sendable` because
/// `UserDefaults` is documented thread-safe but does not yet conform
/// to `Sendable`; the credential store's own conformance covers the
/// other dependency. Safety invariant: every method runs synchronously
/// (no `await`), and the only owner is the MainActor-isolated
/// `TunnelOrchestrator`, so no thread-crossing race can occur in
/// the call sites this app actually exercises.
public struct ProfileStore: @unchecked Sendable {

    private enum Keys {
        static let profiles = "profiles"
        static let selected = "selectedProfileID"
        /// **Pers-F#10 (v0.1.7.17):** namespace for backed-up
        /// corrupt profile blobs. Suffix is an ISO-8601 timestamp.
        static let profilesBroken = "profiles.broken"
    }

    private let defaults: UserDefaults
    private let credentials: any CredentialStore

    public init(
        defaults: UserDefaults = .standard,
        credentials: any CredentialStore
    ) {
        self.defaults = defaults
        self.credentials = credentials
    }

    /// Returns every saved profile **without** filling in passwords.
    /// Eager hydration would force a credential-store hit during app
    /// launch — for the Keychain backend that's an OS prompt before
    /// the UI even renders. The orchestrator pulls the password on
    /// demand inside `start(mode:)`.
    ///
    /// Legacy passwords stored as plaintext inside the `UserDefaults`
    /// blob (pre-Keychain era) are still adopted into the credential
    /// store here, because we already have those bytes in memory and
    /// adopting them is free of any prompt.
    public func loadProfiles() -> [Profile] {
        guard let data = defaults.data(forKey: Keys.profiles) else {
            // First launch — no key set. Return default.
            return [.default]
        }
        // **Pers-F#10 (v0.1.7.17):** previously
        // `try? JSONDecoder().decode(...)` swallowed decode
        // errors and returned `[.default]`. Next `save(profiles:)`
        // would then overwrite the corrupted-but-recoverable
        // blob with the default profile, silently destroying
        // the user's profile list. Now: on decode failure, copy
        // the corrupted blob to a backup key
        // (`Keys.profilesBroken` + ISO timestamp) and surface
        // an `os_log` warning before falling back. The user can
        // recover via `defaults read` if needed.
        let stored: [Profile]
        do {
            stored = try JSONDecoder().decode([Profile].self, from: data)
        } catch {
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let brokenKey = "\(Keys.profilesBroken).\(timestamp)"
            defaults.set(data, forKey: brokenKey)
            Logger.cooltunnel("ProfileStore").error(
                "profiles JSON failed to decode (\(error.localizedDescription, privacy: .public)); preserved as \(brokenKey, privacy: .public)"
            )
            return [.default]
        }
        if stored.isEmpty {
            return [.default]
        }

        var hydrated: [Profile] = []
        var seenIDs: Set<String> = []
        var needsRewrite = false
        // **H2 (v2.0.38):** track per-profile credential-store migration
        // success. The previous implementation used `try?` and
        // unconditionally stripped `profile.password` to `""`, so a
        // failed migration (keychain locked, disk full, dismissed
        // prompt) followed by the rewrite below silently destroyed
        // the user's legacy password — it was now gone from BOTH
        // backends. We now keep the legacy password in the in-memory
        // profile when migration fails, and skip the UserDefaults
        // rewrite for that profile (the password stays where it was).
        var migrationFailedIDs: Set<String> = []
        for var profile in stored {
            // Defensive: drop entries with empty id and dedupe by id.
            // A corrupted UserDefaults plist (TimeMachine restore
            // race, manual `defaults import` mistake) could leave
            // duplicate or empty ids; without this the
            // `selectedProfile` getter returns whichever appears
            // `first`, and `removeSelectedProfile` would delete
            // every match in one keystroke.
            if profile.id.isEmpty || seenIDs.contains(profile.id) {
                needsRewrite = true
                continue
            }
            seenIDs.insert(profile.id)

            let storedSecret = profile.password
            if !storedSecret.isEmpty {
                // Legacy plaintext password lurking in UserDefaults.
                // Promote it into the credential store now (no prompt
                // for the file backend; for the migrating wrapper
                // this is a free write since the file primary is
                // local-only). The strip-from-UserDefaults below is
                // conditional on the migration succeeding.
                do {
                    try credentials.setPassword(storedSecret, forProfileID: profile.id)
                    needsRewrite = true
                    profile.password = ""
                } catch {
                    Logger.cooltunnel("ProfileStore").error(
                        "credential migration failed for profile \(profile.id, privacy: .public): \(error.localizedDescription, privacy: .public); preserving legacy password in UserDefaults until next attempt"
                    )
                    migrationFailedIDs.insert(profile.id)
                    // Intentionally DO NOT clear `profile.password` —
                    // the orchestrator's `password(forProfileID:)`
                    // path will fail the same way the migration just
                    // did, but the in-memory profile this load
                    // returns still carries the password so the
                    // user can start the tunnel.
                }
            } else {
                // Already migrated (or never had a legacy password).
                // The empty-string assignment is a no-op semantically.
                profile.password = ""
            }
            // Trim whitespace at the persistence boundary so a
            // user pasting `alice ` from a chat app doesn't end up
            // failing engine validation with no obvious cause.
            profile.server = profile.server.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.username = profile.username.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.localPort = profile.localPort.trimmingCharacters(in: .whitespacesAndNewlines)
            hydrated.append(profile)
        }
        // If dedupe ate every profile, fall back to the bundled
        // default rather than returning an empty list which the
        // UI doesn't expect.
        if hydrated.isEmpty {
            hydrated = [.default]
            needsRewrite = true
        }

        if needsRewrite {
            // **H2 (v2.0.38):** preserve legacy passwords for profiles
            // whose migration failed; the rewrite would otherwise
            // overwrite the only remaining copy with `""`.
            persistStripped(profiles: hydrated, preservePasswordIDs: migrationFailedIDs)
        }
        return hydrated
    }

    /// Persists the profile list. Each non-empty password is written
    /// to the credential store; the `UserDefaults` blob stores
    /// everything *except* the password.
    ///
    /// **H2 (v2.0.38):** profiles whose credential-store write fails
    /// retain their password in the `UserDefaults` blob — the strip
    /// is conditional on the write succeeding. The previous
    /// implementation `try?`-discarded the credential failure and
    /// then unconditionally stripped, so a transient keychain
    /// failure during save permanently lost the new password.
    public func save(profiles: [Profile]) {
        var credentialWriteFailedIDs: Set<String> = []
        for profile in profiles {
            // Only write when there's something to save — empty means
            // "no change since load" because the orchestrator never
            // round-trips the password through the in-memory profile
            // unless the user actually edited it.
            if !profile.password.isEmpty {
                do {
                    try credentials.setPassword(profile.password, forProfileID: profile.id)
                } catch {
                    Logger.cooltunnel("ProfileStore").error(
                        "credential write failed for profile \(profile.id, privacy: .public): \(error.localizedDescription, privacy: .public); preserving password in UserDefaults until next save"
                    )
                    credentialWriteFailedIDs.insert(profile.id)
                }
            }
        }
        persistStripped(profiles: profiles, preservePasswordIDs: credentialWriteFailedIDs)
    }

    /// Returns the currently selected profile id, or `nil` if none
    /// stored.
    public func loadSelectedID() -> String? {
        defaults.string(forKey: Keys.selected)
    }

    /// Persists the selected profile id (or clears it when `nil`).
    public func save(selectedID: String?) {
        if let id = selectedID {
            defaults.set(id, forKey: Keys.selected)
        } else {
            defaults.removeObject(forKey: Keys.selected)
        }
    }

    /// On-demand password fetch for a profile. The orchestrator calls
    /// this from `start(mode:)` immediately before validating, so a
    /// credential-store access (and any OS prompt the migrating
    /// wrapper may surface) happens after the user has already
    /// committed to launching — never at app boot.
    ///
    /// **H3 (v2.0.38):** propagates the underlying credential-store
    /// error instead of collapsing it to `""`. The previous
    /// `(try? ...) ?? ""` made a keychain lock indistinguishable
    /// from "no password ever set" — the orchestrator surfaced
    /// "enter a password" to the user, who re-typed it and
    /// triggered the H2 save path against the same locked
    /// keychain. The throw forces the caller to make the
    /// "no password" vs "store unreachable" choice explicitly.
    /// Backend implementations still treat "item not found" as
    /// `""` (not an error), per the `CredentialStore` contract.
    public func password(forProfileID id: String) throws -> String {
        try credentials.password(forProfileID: id)
    }

    /// Removes the credential entry for a profile that's been deleted
    /// from the list.
    public func deletePassword(forProfileID id: String) {
        // **M1 (v2.0.38):** log on failure instead of silently
        // swallowing. The caller has already removed the profile id
        // from the in-memory list; a credential-delete failure here
        // means the entry lingers in the keychain / file store with
        // no UI to clean it up. Surfacing the line lets an operator
        // notice the orphan when diagnosing keychain bloat.
        do {
            try credentials.deletePassword(forProfileID: id)
        } catch {
            Logger.cooltunnel("ProfileStore").warning(
                "credential delete failed for profile \(id, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Private

    /// Persists profiles to `UserDefaults` with passwords stripped.
    /// The credential store is responsible for the secrets; this
    /// helper only handles the low-sensitivity blob.
    ///
    /// **H2 (v2.0.38):** `preservePasswordIDs` names profile ids
    /// whose credential-store write or migration just failed.
    /// For those, the password is left intact in the `UserDefaults`
    /// blob — it is the only remaining copy and dropping it would
    /// be silent data loss. Once the underlying credential store
    /// is reachable again, the next save will migrate them through.
    private func persistStripped(
        profiles: [Profile],
        preservePasswordIDs: Set<String> = []
    ) {
        let stripped = profiles.map { profile -> Profile in
            var p = profile
            if !preservePasswordIDs.contains(p.id) {
                p.password = ""
            }
            return p
        }
        // **M1 (v2.0.38):** log on encode failure. `[Profile]` has no
        // custom Codable + no NaN floats, so this realistically can't
        // fail — but if it does, silently abandoning the save would
        // mean the user's profile edit doesn't persist with no
        // diagnostic. The optional-coalesce the previous
        // implementation used hid exactly that class of
        // "shouldn't happen" failure.
        let data: Data
        do {
            data = try JSONEncoder().encode(stripped)
        } catch {
            Logger.cooltunnel("ProfileStore").error(
                "profiles blob encode failed: \(error.localizedDescription, privacy: .public); UserDefaults not updated"
            )
            return
        }
        defaults.set(data, forKey: Keys.profiles)
    }
}
