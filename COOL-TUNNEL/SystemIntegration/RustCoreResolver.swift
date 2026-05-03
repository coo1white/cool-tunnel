// SystemIntegration/RustCoreResolver.swift
//
// Mirror of `NaiveBinaryResolver`, but for the Rust engine
// (`cool-tunnel-core`) instead of the upstream `naive` binary.
//
// Architectural intent (per the v0.2.0 cross-platform diagram):
//
//     Server     UI: Filament (PHP)        Glue: ct-server-core (Rust) + shared ct-protocol     Engine: forwardproxy@naive Caddy plugin
//     macOS      UI: SwiftUI               Glue: cool-tunnel-core  (Rust) + shared ct-protocol  Engine: bundled naive Mach-O
//     Future…    UI: Kotlin/Swift/C++/GTK  Glue: same ct-protocol + per-platform core           Engine: platform-built naive
//
// The "Glue" cell is what this resolver inspects. On macOS today it
// is the Rust binary we build at `core/` and bundle inside the
// .app's Resources directory. The user can override that path from
// Settings → Rust Core → Choose…/Update — same UX as the naive
// resolver — and the resolver verifies it the same way: lipo for
// architectures, `--version` for liveness, codesign for integrity.

import Foundation

/// Snapshot of a single cool-tunnel-core binary candidate. All
/// fields populated by [`RustCoreResolver.inspect`] so the
/// Settings view can render the readout without firing extra
/// subprocesses.
public struct RustCoreDescriptor: Sendable, Equatable {
    public enum Origin: Sendable, Equatable {
        /// The binary that ships inside `Cool tunnel.app/Contents/Resources/`.
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

/// Errors the resolver surfaces. Distinct from `NaiveResolverError`
/// so the UI can show a precise message ("Rust core" vs "naive
/// binary") without runtime introspection.
public enum RustCoreResolverError: Error, Sendable, Equatable {
    case fileNotFound(URL)
    case notAMachO(URL)
    case missingHostSlice(URL, host: HostArchitecture, found: Set<String>)
    case codeSignatureInvalid(URL, CodeSignError)

    public var localizedDescription: String {
        switch self {
        case .fileNotFound(let url):
            "cool-tunnel-core binary not found at \(url.path)"
        case .notAMachO(let url):
            "\(url.path) is not a Mach-O executable"
        case .missingHostSlice(let url, let host, let found):
            "\(url.path) does not contain a \(host.machOArchName) slice "
                + "(found: \(found.sorted().joined(separator: ", ")))"
        case .codeSignatureInvalid(_, let err):
            "code signature check failed: \(err.localizedDescription)"
        }
    }
}

/// Stateless façade that finds, inspects, and validates the active
/// `cool-tunnel-core` binary. Mirrors `NaiveBinaryResolver` so
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
        let archs = await Self.runLipoInfo(at: url)
        guard !archs.isEmpty else {
            throw RustCoreResolverError.notAMachO(url)
        }
        let version: String?
        if archs.contains(HostArchitecture.current.machOArchName) {
            version = await Self.runVersion(at: url)
        } else {
            version = nil
        }
        let signatureValid = await Self.checkSignature(at: url)
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

    // MARK: - Subprocess helpers (same shape as NaiveBinaryResolver)

    private static func runLipoInfo(at url: URL) async -> Set<String> {
        let result = await runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/lipo"),
            arguments: ["-info", url.path]
        )
        guard let output = result, !output.isEmpty else { return [] }
        guard
            let tail =
                output
                .components(separatedBy: ":")
                .last?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return [] }
        let tokens =
            tail
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        let known: Set<String> = ["arm64", "arm64e", "x86_64", "i386"]
        return Set(tokens.filter { known.contains($0) })
    }

    /// Invokes the binary with `--version` and accepts only output
    /// that matches the canonical pattern
    /// `cool-tunnel-core <semver>`. Same defence-in-depth posture
    /// as `NaiveBinaryResolver.runVersion` — a misbehaving binary
    /// can't put arbitrary text into the Settings UI.
    private static func runVersion(at url: URL) async -> String? {
        let output = await runProcess(executable: url, arguments: ["--version"])
        guard let raw = output else { return nil }
        // Pattern allows the standard semver shape Cargo emits
        // (`MAJOR.MINOR.PATCH`) plus an optional pre-release
        // suffix and an optional 4th `.PATCH2` segment for our
        // own 4-component marketing version (e.g. 0.1.5.7).
        let pattern = #"^cool-tunnel-core\s+\d+(\.\d+){0,3}(-[A-Za-z0-9.]+)?\s*$"#
        for line in raw.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.range(of: pattern, options: .regularExpression) != nil {
                return trimmed
            }
        }
        return nil
    }

    private static func checkSignature(at url: URL) async -> Bool {
        do {
            try await CodeSignVerifier.verifyValid(at: url)
            return true
        } catch {
            return false
        }
    }

    private static func runProcess(executable: URL, arguments: [String]) async -> String? {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            do {
                try process.run()
            } catch {
                return nil
            }
            process.waitUntilExit()
            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            let combined = stdout.isEmpty ? stderr : stdout
            return combined
        }.value
    }
}
