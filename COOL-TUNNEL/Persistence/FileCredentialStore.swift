// Persistence/FileCredentialStore.swift
//
// File-backed primary credential store. Replaces the macOS Keychain
// as the default password backend so the app never has to trigger a
// system-password / "approve keychain access" prompt before the UI
// appears.
//
// On-disk layout:
//
//   ~/Library/Application Support/COOL-TUNNEL/credentials.json   (mode 0600)
//
// File format: a flat JSON map of `{ profileID: passwordBase64 }`.
// Base64 is *not* encryption — it just stops a user accidentally
// reading their own credentials by opening the file in a text
// editor, and prevents `grep` over the support directory from
// turning the password up as plain UTF-8. Real protection comes
// from the file's POSIX mode (0600 — user-only read/write) and
// from the parent directory's mode (0700, set by `AppSupportPaths`).
//
// Concurrency: the read-modify-write cycle inside `setPassword` /
// `deletePassword` is serialised by an `NSLock`. This protects
// against two stores in the same process racing on the file. The
// store does **not** guard against multiple **processes** writing
// the same file concurrently — which can't happen in practice
// (only the running app touches it) and would be the wrong layer
// to fix here anyway.

import Foundation

/// Errors raised by [`FileCredentialStore`]. Distinct from
/// `KeychainError` so the wire-level surface tells you which backend
/// failed.
public enum FileCredentialError: Error, Sendable, Equatable {
    /// Reading or writing the JSON file failed at the OS level.
    case io(String)
    /// The JSON file exists but does not parse as `{ String: String }`.
    case malformed
    /// A stored value did not decode as UTF-8 after base64 unwrap.
    case malformedItem

    public var localizedDescription: String {
        switch self {
        case .io(let message): "credentials file I/O failed: \(message)"
        case .malformed: "credentials file is malformed JSON"
        case .malformedItem: "credentials entry is not valid UTF-8"
        }
    }
}

/// File-backed implementation of [`CredentialStore`]. Marked
/// `@unchecked Sendable` because the internal `NSLock` makes the
/// store safe to share across actors — the compiler can't see
/// that. Safety invariant: every public method takes the lock
/// before touching the on-disk JSON table and releases it
/// synchronously before returning, so no thread can observe
/// torn state regardless of which actor calls in.
public final class FileCredentialStore: CredentialStore, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    /// Constructs a store backed by the given file URL. The caller is
    /// responsible for ensuring the parent directory exists with the
    /// expected 0700 mode — `AppSupportPaths` does this once at
    /// launch.
    public init(url: URL) {
        self.url = url
    }

    /// Convenience factory that places the credentials file inside
    /// the app's standard support directory.
    public static func defaultStore(paths: AppSupportPaths) -> FileCredentialStore {
        FileCredentialStore(
            url: paths.supportDirectory.appendingPathComponent(
                "credentials.json",
                isDirectory: false
            )
        )
    }

    // MARK: - CredentialStore

    public func password(forProfileID id: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        let table = try loadLocked()
        guard let encoded = table[id], !encoded.isEmpty else { return "" }
        guard let data = Data(base64Encoded: encoded),
            let plain = String(data: data, encoding: .utf8)
        else {
            throw FileCredentialError.malformedItem
        }
        return plain
    }

    public func setPassword(_ password: String, forProfileID id: String) throws {
        if password.isEmpty {
            try deletePassword(forProfileID: id)
            return
        }
        lock.lock()
        defer { lock.unlock() }
        var table = try loadLocked()
        table[id] = Data(password.utf8).base64EncodedString()
        try saveLocked(table)
    }

    public func deletePassword(forProfileID id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var table = try loadLocked()
        guard table.removeValue(forKey: id) != nil else { return }
        try saveLocked(table)
    }

    // MARK: - Private

    /// Loads the JSON table off disk. Returns an empty dict when the
    /// file does not exist yet — first-write callers see a clean
    /// slate. Caller must hold `lock`.
    private func loadLocked() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return [:]
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw FileCredentialError.io(error.localizedDescription)
        }
        if data.isEmpty { return [:] }
        do {
            let table = try JSONDecoder().decode([String: String].self, from: data)
            return table
        } catch {
            throw FileCredentialError.malformed
        }
    }

    /// Writes the JSON table back to disk **atomically** with mode
    /// 0600. The atomic write avoids the half-written-file failure
    /// mode if the process is killed mid-write. Caller must hold
    /// `lock`.
    private func saveLocked(_ table: [String: String]) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(table)
        } catch {
            throw FileCredentialError.io(error.localizedDescription)
        }
        do {
            try RestrictedFile.write(data, to: url)
        } catch {
            throw FileCredentialError.io(error.localizedDescription)
        }
    }
}
