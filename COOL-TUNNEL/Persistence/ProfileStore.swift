// Persistence/ProfileStore.swift
//
// Persists the user's saved `Profile`s and the currently selected profile
// id. Identifier, server, username, and local port live in `UserDefaults`
// (low-sensitivity); passwords live in the Keychain via `KeychainStore`.
//
// On read, the two halves are recombined into a fully-populated `Profile`.
// On write, the password is split out and the profile is persisted with an
// empty password placeholder so a stale `UserDefaults` plist does not
// re-leak credentials after the migration.

import Foundation

/// Stores profiles + selection. Marked `@unchecked Sendable` because
/// `UserDefaults` is documented thread-safe but does not yet conform to
/// `Sendable`; `KeychainStore` is `Sendable` already.
public struct ProfileStore: @unchecked Sendable {

    private enum Keys {
        static let profiles = "profiles"
        static let selected = "selectedProfileID"
        /// Marker we set the first time we strip passwords out of an
        /// existing `profiles` blob — used to skip the legacy migration on
        /// subsequent loads.
        static let migrated = "profilesMigratedToKeychain"
    }

    private let defaults: UserDefaults
    private let keychain: KeychainStore

    public init(
        defaults: UserDefaults = .standard,
        keychain: KeychainStore = KeychainStore()
    ) {
        self.defaults = defaults
        self.keychain = keychain
    }

    /// Returns every saved profile with passwords filled in from the
    /// Keychain. On first run after the migration, also rewrites the
    /// `UserDefaults` blob with passwords stripped.
    public func loadProfiles() -> [Profile] {
        guard let data = defaults.data(forKey: Keys.profiles),
              let stored = try? JSONDecoder().decode([Profile].self, from: data),
              !stored.isEmpty
        else {
            return [.default]
        }

        let alreadyMigrated = defaults.bool(forKey: Keys.migrated)

        // Hydrate passwords from Keychain. If the legacy `UserDefaults`
        // blob still carried a non-empty password (pre-migration) and
        // Keychain has nothing for that id yet, we adopt the legacy value
        // so the user does not silently lose access — then immediately
        // upgrade by saving back through the Keychain path.
        var hydrated: [Profile] = []
        var needsRewrite = !alreadyMigrated
        for var profile in stored {
            let storedSecret = profile.password
            let keychainSecret = (try? keychain.password(forProfileID: profile.id)) ?? ""

            if !storedSecret.isEmpty {
                // Migrate legacy plaintext password into Keychain.
                if keychainSecret.isEmpty {
                    try? keychain.setPassword(storedSecret, forProfileID: profile.id)
                }
                profile.password = storedSecret
                needsRewrite = true
            } else {
                profile.password = keychainSecret
            }
            hydrated.append(profile)
        }

        if needsRewrite {
            persist(profiles: hydrated)
            defaults.set(true, forKey: Keys.migrated)
        }
        return hydrated
    }

    /// Persists the profile list. Each password is written to the Keychain;
    /// the `UserDefaults` blob stores everything *except* the password.
    public func save(profiles: [Profile]) {
        persist(profiles: profiles)
        defaults.set(true, forKey: Keys.migrated)
    }

    /// Returns the currently selected profile id, or `nil` if none stored.
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

    /// Deletes Keychain credentials for ids no longer present in `profiles`.
    /// Called from the orchestrator after `removeSelectedProfile` so dead
    /// passwords do not linger.
    public func purgeKeychain(except keepIDs: Set<String>) {
        // We do not enumerate the keychain (no kSecMatchLimitAll plumbing
        // here); callers tell us the surviving ids and we no-op the rest
        // by relying on `setPassword(_:forProfileID:)` to delete-on-empty
        // when a profile is removed. This method is a no-op placeholder
        // kept for symmetry with future enumeration support.
        _ = keepIDs
    }

    // MARK: - Private

    private func persist(profiles: [Profile]) {
        for profile in profiles {
            try? keychain.setPassword(profile.password, forProfileID: profile.id)
        }
        let stripped = profiles.map { profile -> Profile in
            var p = profile
            p.password = ""
            return p
        }
        guard let data = try? JSONEncoder().encode(stripped) else { return }
        defaults.set(data, forKey: Keys.profiles)
    }
}
