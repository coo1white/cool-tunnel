// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
// Persistence/KeychainStore.swift
//
// Stores per-profile passwords in the macOS login Keychain. Replaces the
// previous behaviour of serialising passwords as plaintext inside the
// `profiles` JSON blob in `UserDefaults` (which is world-readable for the
// user account, captured by Time Machine, and trivially leakable).
//
// Each profile id maps to a single generic-password keychain item:
//   service: "space.coolwhite.naive.proxy-credentials"
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
    /// `errSecItemNotFound`, which is treated as "no password yet").
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

/// Per-profile password storage backed by the macOS Keychain.
public struct KeychainStore: Sendable {

    /// Default service identifier used to namespace this app's keychain
    /// items. Bundle id plus a stable suffix so multiple credential kinds
    /// can share the keychain in the future without collision.
    public static let defaultService = "space.coolwhite.naive.proxy-credentials"

    private let service: String

    public init(service: String = KeychainStore.defaultService) {
        self.service = service
    }

    /// Writes (or updates) the password associated with a profile id.
    ///
    /// Empty passwords are deleted rather than stored — there is no point
    /// in keeping a sentinel "no password" item.
    public func setPassword(_ password: String, forProfileID id: String) throws {
        if password.isEmpty {
            try deletePassword(forProfileID: id)
            return
        }
        let data = Data(password.utf8)

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

    /// Returns the password associated with a profile id, or an empty string
    /// when none is stored. Throws on unexpected keychain errors.
    public func password(forProfileID id: String) throws -> String {
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
                let password = String(data: data, encoding: .utf8)
            else { throw KeychainError.malformedItem }
            return password
        case errSecItemNotFound:
            return ""
        default:
            throw KeychainError.read(status)
        }
    }

    /// Removes the password associated with a profile id. No-op when none
    /// is stored.
    public func deletePassword(forProfileID id: String) throws {
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
