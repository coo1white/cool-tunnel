// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
// Persistence/KeychainStore.swift
//
// Stores per-profile VLESS UUIDs in the macOS login Keychain. v3.0.0
// successor to the v2.x NaiveProxy-password store; the storage shape
// (one generic-password keychain item per profile) is unchanged, but
// the service identifier renames so a v2.x in-place upgrade does NOT
// resurrect a stored basic-auth password as a v3.0.0 VLESS UUID
// (those are categorically different credentials; surfacing the v2.x
// bytes to sing-box would fail the UUID parse with a confusing error).
//
// Each profile id maps to a single generic-password keychain item:
//   service: "space.coolwhite.naive.vless-credentials"
//   account: profile.id
//   accessibility: WhenUnlocked

import Foundation
import Security

/// Errors raised by [`KeychainStore`].
///
/// Conforms to `LocalizedError` so a user-facing catch site
/// surfaces the strings below rather than Swift's default
/// `"…CoolTunnel.KeychainError error N."` placeholder.
public enum KeychainError: LocalizedError, Sendable, Equatable {
    /// `SecItemAdd` / `SecItemUpdate` failed.
    case write(OSStatus)
    /// `SecItemCopyMatching` failed with an unexpected status (other than
    /// `errSecItemNotFound`, which is treated as "no credential yet").
    case read(OSStatus)
    /// `SecItemDelete` failed with an unexpected status.
    case delete(OSStatus)
    /// The stored item did not decode as UTF-8.
    case malformedItem

    public var errorDescription: String? {
        switch self {
        case .write(let s): "Keychain write failed (OSStatus \(s))."
        case .read(let s): "Keychain read failed (OSStatus \(s))."
        case .delete(let s): "Keychain delete failed (OSStatus \(s))."
        case .malformedItem: "Keychain item is not valid UTF-8."
        }
    }
}

/// Per-profile credential storage backed by the macOS Keychain.
///
/// **v3.0.0 (sub-phase F):** stores VLESS UUIDs (the v3.0.0 sing-box
/// per-account credential). The v2.x service identifier
/// (`…proxy-credentials`) is intentionally NOT migrated forward:
/// a v2.x basic-auth password is the wrong shape for a VLESS user_id
/// and surfacing it would fail the engine's `Uuid::parse` with a
/// confusing "uuid must be an RFC 4122 hyphenated UUID" error. The
/// in-place upgrade path is "the keychain has no UUID; force the
/// user through the subscription URL re-import flow", which is the
/// same path a fresh install takes.
public struct KeychainStore: Sendable {

    /// Default service identifier used to namespace this app's keychain
    /// items. Bundle id plus a stable suffix so multiple credential kinds
    /// can share the keychain in the future without collision.
    ///
    /// **v3.0.0 (sub-phase F):** renamed from `…proxy-credentials`
    /// to `…vless-credentials`. The `.naive.` segment is retained
    /// because it matches the `PRODUCT_BUNDLE_IDENTIFIER`
    /// (`space.coolwhite.naive`) which is the cross-version
    /// persistence anchor — changing the bundle id would break
    /// every other in-place upgrade surface (UserDefaults,
    /// preferences, code-signing identity). Only the trailing
    /// credential-kind segment changed, so the keychain partitions
    /// cleanly between v2.x basic-auth passwords (untouched and
    /// orphaned after upgrade) and v3.0.0 VLESS UUIDs.
    public static let defaultService = "space.coolwhite.naive.vless-credentials"

    private let service: String

    public init(service: String = KeychainStore.defaultService) {
        self.service = service
    }

    /// Writes (or updates) the UUID associated with a profile id.
    ///
    /// Empty UUIDs are deleted rather than stored — there is no point
    /// in keeping a sentinel "no credential" item.
    public func setUUID(_ uuid: String, forProfileID id: String) throws {
        if uuid.isEmpty {
            try deleteUUID(forProfileID: id)
            return
        }
        let data = Data(uuid.utf8)

        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
        ]
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]

        let updateStatus = SecItemUpdate(lookup as CFDictionary, updateAttrs as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = lookup
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.write(addStatus)
            }
        default:
            throw KeychainError.write(updateStatus)
        }
    }

    /// Returns the UUID associated with a profile id, or an empty string
    /// when none is stored. Throws on unexpected keychain errors.
    public func uuid(forProfileID id: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                let uuid = String(data: data, encoding: .utf8)
            else { throw KeychainError.malformedItem }
            return uuid
        case errSecItemNotFound:
            return ""
        default:
            throw KeychainError.read(status)
        }
    }

    /// Removes the UUID associated with a profile id. No-op when none
    /// is stored.
    public func deleteUUID(forProfileID id: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.delete(status)
        }
    }
}

// CredentialStore conformance lives here (with the type) per
// Swift convention. The protocol surface itself is defined in
// CredentialStore.swift; KeychainStore already implements every
// method by name + signature, so the conformance is empty.
extension KeychainStore: CredentialStore {}
