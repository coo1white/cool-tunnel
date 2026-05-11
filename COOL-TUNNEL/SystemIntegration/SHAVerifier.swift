// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
// SystemIntegration/SHAVerifier.swift
//
// Shared SHA-256 verification primitives used by AppUpdater and
// RustCoreUpdater for manifest-pinned downloads. Lifted out of
// `AppUpdater` in v0.1.7.18 because the second consumer
// (RustCoreUpdater SHA pinning, partial Sw#C4 fix) needed the
// same primitives.

import CryptoKit
import Foundation

/// Shared SHA-256 verification primitives. All methods are
/// `nonisolated` so they can be called from background actors
/// without hopping to MainActor.
public enum SHAVerifier {

    /// Streams `fileURL` through CryptoKit's incremental SHA-256
    /// in 64 KiB chunks. Avoids `Data(contentsOf:)` which would
    /// load the full file into memory — meaningful on Intel Macs
    /// hashing a 100 MB .zip.
    public static func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }  // try-ok: defer-block handle teardown
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Reads a `shasum -a 256`-style manifest from `manifestURL`
    /// and returns the lowercase hex hash for `assetName`.
    /// Returns nil if the asset isn't in the manifest, or if
    /// the entry is structurally malformed (not 64 hex chars).
    ///
    /// The manifest format (BSD/Linux `shasum` default):
    ///
    ///     <64 hex chars><two spaces><filename>
    ///     <64 hex chars><two spaces><filename>
    ///     ...
    ///
    /// Multiple entries OK; the first match for `assetName`
    /// wins. The asset filename match is exact (no path
    /// components, no glob).
    public static func expectedHash(
        for assetName: String, in manifestURL: URL
    ) throws -> String? {
        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
        for line in manifest.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let name = String(parts.last ?? "")
            if name == assetName {
                let hash = String(parts[0]).lowercased()
                guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else {
                    return nil
                }
                return hash
            }
        }
        return nil
    }
}
