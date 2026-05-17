// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
// SystemIntegration/RustCoreResolver.swift
//
// Mirror of `SingboxBinaryResolver`, but for the Rust engine
// (`cool-tunnel-core`) instead of the upstream `sing-box` binary.
//
// Architectural intent (per the v3.0.0 cross-platform diagram):
//
//     Server     UI: Filament (PHP)        Glue: ct-server-core (Rust) + shared ct-protocol     Engine: bundled sing-box
//     macOS      UI: SwiftUI               Glue: cool-tunnel-core  (Rust) + shared ct-protocol  Engine: bundled sing-box Mach-O
//     Future…    UI: Kotlin/Swift/C++/GTK  Glue: same ct-protocol + per-platform core           Engine: platform-built sing-box
//
// The "Glue" cell is what this resolver inspects. On macOS today it
// is the Rust binary we build at `core/` and bundle inside the
// .app's Resources directory. The user can override that path from
// Settings → Rust Core → Choose…/Update — same UX as the sing-box
// resolver — and the resolver verifies it the same way: lipo for
// architectures, `--version` for liveness, codesign for integrity.

import Foundation

/// Snapshot of a single cool-tunnel-core binary candidate. All
/// fields populated by [`RustCoreResolver.inspect`] so the
/// Settings view can render the readout without firing extra
/// subprocesses.
public struct RustCoreDescriptor: Sendable, Equatable {
    public enum Origin: Sendable, Equatable {
        /// The binary that ships inside `Cool Tunnel.app/Contents/Resources/`.
        case bundled
        /// A path the user picked or that `RustCoreUpdater` installed.
        case userSupplied
    }

    public let url: URL
    public let origin: Origin
    /// Mach-O architecture slices found in the file (e.g. `arm64`,
    /// `x86_64`). Empty if `lipo -info` failed.
    public let architectures: Set<String>
    /// Version line reported by `cool-tunnel-core --version`,
    /// e.g. `cool-tunnel-core 0.1.5`. `nil` if the binary refused
    /// to print one.
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

/// Errors the resolver surfaces. Distinct from
/// `SingboxResolverError` so the UI can show a precise message
/// ("Rust core" vs "sing-box binary") without runtime
/// introspection.
///
/// **Conforms to `LocalizedError`** and uses
/// `url.lastPathComponent` (filename) instead of `url.path`
/// (absolute path with macOS username) — same discipline as
/// `SingboxResolverError`.
public enum RustCoreResolverError: LocalizedError, Sendable, Equatable {
    case fileNotFound(URL)
    case notAMachO(URL)
    case missingHostSlice(URL, host: HostArchitecture, found: Set<String>)
    case codeSignatureInvalid(URL, CodeSignError)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            "cool-tunnel-core binary '\(url.lastPathComponent)' not found."
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
/// `cool-tunnel-core` binary. Mirrors `SingboxBinaryResolver` so
/// SettingsView can reuse the same verdict-rendering helpers
/// without per-binary special-casing.
public struct RustCoreResolver: Sendable {

    public init() {}

    /// Returns a descriptor for the candidate path, surfacing typed
    /// errors when host-arch slice / code signature checks fail.
    /// Used by `Settings → Rust Core → Test`.
    public func resolve(customPath: String) async throws -> RustCoreDescriptor {
        let url: URL
        let origin: RustCoreDescriptor.Origin
        if customPath.isEmpty {
            url = Self.bundledURL()
            origin = .bundled
        } else {
            url = URL(fileURLWithPath: customPath)
            origin = .userSupplied
        }

        let descriptor = try await inspect(url: url, origin: origin)

        guard descriptor.supportsHostArchitecture else {
            throw RustCoreResolverError.missingHostSlice(
                url,
                host: HostArchitecture.current,
                found: descriptor.architectures
            )
        }
        guard descriptor.isCodeSignatureValid else {
            do {
                try await CodeSignVerifier.verifyValid(at: url)
                return descriptor
            } catch let error as CodeSignError {
                throw RustCoreResolverError.codeSignatureInvalid(url, error)
            }
        }
        return descriptor
    }

    /// Inspects a candidate without raising. Settings view uses this
    /// flavour so the panel can render a NG verdict for an
    /// otherwise-unusable binary instead of throwing the user back
    /// to a stack-trace-flavoured error.
    public func inspect(
        url: URL,
        origin: RustCoreDescriptor.Origin
    ) async throws -> RustCoreDescriptor {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RustCoreResolverError.fileNotFound(url)
        }
        let archs = await BinaryInspector.runLipoInfo(at: url)
        guard !archs.isEmpty else {
            throw RustCoreResolverError.notAMachO(url)
        }
        let version: String?
        if archs.contains(HostArchitecture.current.machOArchName) {
            version = await BinaryInspector.runVersion(
                at: url,
                binaryName: "cool-tunnel-core"
            )
        } else {
            version = nil
        }
        let signatureValid = await BinaryInspector.checkSignature(at: url)
        return RustCoreDescriptor(
            url: url,
            origin: origin,
            architectures: archs,
            version: version,
            isCodeSignatureValid: signatureValid
        )
    }

    /// Path the bundled engine ships at inside the running app
    /// bundle's `Contents/Resources/` directory.
    public static func bundledURL() -> URL {
        Bundle.main.url(forResource: "cool-tunnel-core", withExtension: nil)
            ?? Bundle.main.bundleURL.appendingPathComponent(
                "Contents/Resources/cool-tunnel-core"
            )
    }
}
