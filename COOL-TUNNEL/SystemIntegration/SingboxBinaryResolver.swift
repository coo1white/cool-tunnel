// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
// SystemIntegration/SingboxBinaryResolver.swift
//
// Centralises everything we need to know about the bundled `sing-box`
// Mach-O before we hand its path to the Rust supervisor: where it
// lives, which CPU architectures it contains, what version it
// reports, and whether its code signature is intact.
//
// The resolver is the single place that knows how a custom user-supplied
// binary differs from the bundled default. The orchestrator just asks
// `resolve(...)` and gets back a descriptor it can either spawn from or
// surface as an error in the UI.
//
// **v3.0.0:** renamed from `NaiveBinaryResolver`. The v2.x naive era
// is gone — the bundled binary the engine spawns is now upstream
// `sing-box` (SagerNet), wrapping the VLESS+Reality transport that
// replaced HTTP/2 basic-auth.

import Foundation

/// Snapshot of a single sing-box binary candidate. All fields are
/// populated by [`SingboxBinaryResolver.inspect`] so the Settings
/// view can render the full picture without firing extra subprocesses.
public struct SingboxBinaryDescriptor: Sendable, Equatable {
    public enum Origin: Sendable, Equatable {
        /// The binary that ships inside `Cool Tunnel.app/Contents/Resources/`.
        case bundled
        /// A path the user picked themselves via Settings → Choose…
        case userSupplied
    }

    public let url: URL
    public let origin: Origin
    /// Mach-O architecture slices found in the file (e.g. `arm64`,
    /// `x86_64`). Empty if `lipo -info` failed.
    public let architectures: Set<String>
    /// Version line reported by `sing-box version`, e.g.
    /// `sing-box 1.13.12`. `nil` if the binary refused to print one.
    public let version: String?
    /// `true` once `SecStaticCodeCheckValidity` accepts the file.
    public let isCodeSignatureValid: Bool

    public var supportsHostArchitecture: Bool {
        architectures.contains(HostArchitecture.current.machOArchName)
    }

    public var isUniversal: Bool { architectures.count > 1 }

    public init(
        url: URL,
        origin: Origin,
        architectures: Set<String>,
        version: String?,
        isCodeSignatureValid: Bool
    ) {
        self.url = url
        self.origin = origin
        self.architectures = architectures
        self.version = version
        self.isCodeSignatureValid = isCodeSignatureValid
    }
}

/// Errors the resolver can surface back to the orchestrator. Each one
/// maps to a specific user-facing message in the UI.
///
/// **Conforms to `LocalizedError`**, and uses `url.lastPathComponent`
/// (the filename) in user-visible strings rather than `url.path`
/// (the absolute path, which leaks the macOS username when the
/// binary lives under `/Users/<name>/Library/...`). Support
/// diagnosis still has the full path via the wrapped `URL` value
/// — callers that want it can inspect the associated value
/// directly.
public enum SingboxResolverError: LocalizedError, Sendable, Equatable {
    /// The candidate path does not exist or is not a regular file.
    case fileNotFound(URL)
    /// `lipo` failed to read the file as a Mach-O.
    case notAMachO(URL)
    /// The Mach-O has no slice for the host CPU. Spawning would fail
    /// with "Bad CPU type in executable" — we refuse up front.
    case missingHostSlice(URL, host: HostArchitecture, found: Set<String>)
    /// Code signature is missing or broken. Forwarded from
    /// [`CodeSignVerifier`].
    case codeSignatureInvalid(URL, CodeSignError)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            "sing-box binary '\(url.lastPathComponent)' not found."
        case .notAMachO(let url):
            "'\(url.lastPathComponent)' is not a Mach-O executable."
        case .missingHostSlice(let url, let host, let found):
            "'\(url.lastPathComponent)' does not contain a \(host.machOArchName) slice "
                + "(found: \(found.sorted().joined(separator: ", "))). "
                + "Replace with a universal or \(host.machOArchName) build."
        case .codeSignatureInvalid(_, let err):
            "Code signature check failed: \(err.errorDescription ?? "unknown error")"
        }
    }
}

/// Stateless façade that finds, inspects, and validates the active
/// `sing-box` binary. Designed so the orchestrator never touches
/// `Bundle` or `lipo` directly.
public struct SingboxBinaryResolver: Sendable {

    public init() {}

    // MARK: - Public API

    /// Returns the descriptor for whichever binary the app should spawn,
    /// honouring the user's `customSingboxBinaryPath` override and falling
    /// back to the bundled default. Validates host-arch presence and
    /// code signature; surfaces a typed error if either fails so the UI
    /// can render an actionable message.
    public func resolve(settings: AppSettings) async throws -> SingboxBinaryDescriptor {
        let url: URL
        let origin: SingboxBinaryDescriptor.Origin
        if !settings.customSingboxBinaryPath.isEmpty {
            url = URL(fileURLWithPath: settings.customSingboxBinaryPath)
            origin = .userSupplied
        } else {
            url = Self.bundledURL()
            origin = .bundled
        }

        let descriptor = try await inspect(url: url, origin: origin)

        guard descriptor.supportsHostArchitecture else {
            throw SingboxResolverError.missingHostSlice(
                url,
                host: HostArchitecture.current,
                found: descriptor.architectures
            )
        }
        guard descriptor.isCodeSignatureValid else {
            // Re-run the check just to extract the OSStatus for the
            // typed error. If the fresh check now passes (race between
            // inspect and resolve), trust it and return the descriptor;
            // Swift's `guard` requires us to exit the scope explicitly,
            // so the success path returns from inside the `do`.
            do {
                try await CodeSignVerifier.verifyValid(at: url)
                return descriptor
            } catch let error as CodeSignError {
                throw SingboxResolverError.codeSignatureInvalid(url, error)
            }
        }
        return descriptor
    }

    /// Returns a descriptor without raising on missing host arch or bad
    /// signature. Used by Settings to *describe* a candidate to the user
    /// before they commit. All fields are populated even on failure so
    /// the UI can render a full diagnostic panel.
    public func inspect(
        url: URL,
        origin: SingboxBinaryDescriptor.Origin
    ) async throws -> SingboxBinaryDescriptor {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SingboxResolverError.fileNotFound(url)
        }

        let archs = await BinaryInspector.runLipoInfo(at: url)
        guard !archs.isEmpty else {
            throw SingboxResolverError.notAMachO(url)
        }
        // We only attempt `version` if the binary contains the host
        // slice. Spawning a foreign-arch executable would just print
        // "Bad CPU type in executable" and waste time.
        let version: String?
        if archs.contains(HostArchitecture.current.machOArchName) {
            version = await BinaryInspector.runVersion(at: url, binaryName: "sing-box")
        } else {
            version = nil
        }
        let signatureValid = await BinaryInspector.checkSignature(at: url)
        return SingboxBinaryDescriptor(
            url: url,
            origin: origin,
            architectures: archs,
            version: version,
            isCodeSignatureValid: signatureValid
        )
    }

    /// Path to the bundled sing-box binary inside the running app
    /// bundle's `Contents/Resources/` directory. Mirrors the
    /// `scripts/fetch_singbox-core.ts` `DEST` constant — both ends
    /// agree on `COOL-TUNNEL/sing-box` as the bundled path.
    public static func bundledURL() -> URL {
        Bundle.main.url(forResource: "sing-box", withExtension: nil)
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/sing-box")
    }
}
