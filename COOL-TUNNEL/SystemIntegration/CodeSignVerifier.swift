// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
// SystemIntegration/CodeSignVerifier.swift
//
// Wrapper around `SecStaticCodeCheckValidity` for tampering detection on
// every binary the app spawns: the bundled `cool-tunnel-core` engine and
// any user-supplied `sing-box` Mach-O.
//
// Validation here means: the binary has an intact code signature. Tampering
// (replacing the file, modifying its bytes, stripping the signature) makes
// the call fail. We deliberately do *not* require a specific identity so a
// user can drop in their own `sing-box` build, but the binary must be signed.

import Foundation
import Security

/// Errors produced by [`CodeSignVerifier`].
///
/// **Conforms to `LocalizedError`** so the `(error as? LocalizedError)
/// ?.errorDescription` cast at user-facing catch sites surfaces the
/// strings below rather than Swift's default
/// `"…CoolTunnel.CodeSignError error N."` placeholder. The OSStatus
/// numbers are kept for support diagnosis but the user-facing
/// half of each message reads as plain English.
public enum CodeSignError: LocalizedError, Sendable, Equatable {
    /// `SecStaticCodeCreateWithPath` could not create a static code handle.
    /// The path may not exist, may not be a Mach-O, or may not be readable.
    case cannotCreateStaticCode(OSStatus)
    /// The signature is missing, broken, or its hashes do not match the
    /// binary's bytes — i.e. the file has been tampered with.
    case invalidSignature(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .cannotCreateStaticCode(let status):
            "Cool Tunnel could not read the binary's code signature (OSStatus \(status))."
        case .invalidSignature(let status):
            "The binary's code signature is invalid or missing (OSStatus \(status))."
        }
    }
}

/// Stateless verifier for Mach-O code signatures.
public enum CodeSignVerifier {

    /// Throws if the binary at `url` is not validly code-signed.
    ///
    /// Detects: an unsigned binary, a binary with a stripped signature, a
    /// binary whose bytes have been modified after signing, an ad-hoc
    /// signature with broken hashes. Does **not** restrict signing identity
    /// — callers can layer team-id checks on top if needed.
    public static func verifyValid(at url: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try Self.verifyValidSync(at: url)
        }.value
    }

    private static func verifyValidSync(at url: URL) throws {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            url as CFURL,
            SecCSFlags(rawValue: 0),
            &staticCode
        )
        guard createStatus == errSecSuccess, let code = staticCode else {
            throw CodeSignError.cannotCreateStaticCode(createStatus)
        }

        let checkStatus = SecStaticCodeCheckValidity(
            code,
            SecCSFlags(rawValue: 0),
            nil
        )
        guard checkStatus == errSecSuccess else {
            throw CodeSignError.invalidSignature(checkStatus)
        }
    }
}
