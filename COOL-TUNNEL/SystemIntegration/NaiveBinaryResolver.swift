// SystemIntegration/NaiveBinaryResolver.swift
//
// Centralises everything we need to know about the `naive` Mach-O before
// we hand its path to the Rust supervisor: where it lives, which CPU
// architectures it contains, what version it reports, and whether its
// code signature is intact.
//
// The resolver is the single place that knows how a custom user-supplied
// binary differs from the bundled default. The orchestrator just asks
// `resolve(...)` and gets back a descriptor it can either spawn from or
// surface as an error in the UI.

import Foundation

/// Snapshot of a single naive binary candidate. All fields are populated
/// by [`NaiveBinaryResolver.inspect`] so the Settings view can render the
/// full picture without firing extra subprocesses.
public struct NaiveBinaryDescriptor: Sendable, Equatable {
    public enum Origin: Sendable, Equatable {
        /// The binary that ships inside `Cool tunnel.app/Contents/Resources/`.
        case bundled
        /// A path the user picked themselves via Settings → Choose…
        case userSupplied
    }

    public let url: URL
    public let origin: Origin
    /// Mach-O architecture slices found in the file (e.g. `arm64`,
    /// `x86_64`). Empty if `lipo -info` failed.
    public let architectures: Set<String>
    /// Version line reported by `naive --version`, e.g.
    /// `naive 147.0.7727.49`. `nil` if the binary refused to print one.
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
public enum NaiveResolverError: Error, Sendable, Equatable {
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

    public var localizedDescription: String {
        switch self {
        case .fileNotFound(let url):
            "naive binary not found at \(url.path)"
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
/// `naive` binary. Designed so the orchestrator never touches `Bundle`
/// or `lipo` directly.
public struct NaiveBinaryResolver: Sendable {

    public init() {}

    // MARK: - Public API

    /// Returns the descriptor for whichever binary the app should spawn,
    /// honouring the user's `customNaiveBinaryPath` override and falling
    /// back to the bundled default. Validates host-arch presence and
    /// code signature; surfaces a typed error if either fails so the UI
    /// can render an actionable message.
    public func resolve(settings: AppSettings) async throws -> NaiveBinaryDescriptor {
        let url: URL
        let origin: NaiveBinaryDescriptor.Origin
        if !settings.customNaiveBinaryPath.isEmpty {
            url = URL(fileURLWithPath: settings.customNaiveBinaryPath)
            origin = .userSupplied
        } else {
            url = Self.bundledURL()
            origin = .bundled
        }

        let descriptor = try await inspect(url: url, origin: origin)

        guard descriptor.supportsHostArchitecture else {
            throw NaiveResolverError.missingHostSlice(
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
                throw NaiveResolverError.codeSignatureInvalid(url, error)
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
        origin: NaiveBinaryDescriptor.Origin
    ) async throws -> NaiveBinaryDescriptor {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NaiveResolverError.fileNotFound(url)
        }

        let archs = await Self.runLipoInfo(at: url)
        guard !archs.isEmpty else {
            throw NaiveResolverError.notAMachO(url)
        }
        // We only attempt `--version` if the binary contains the host
        // slice. Spawning a foreign-arch executable would just print
        // "Bad CPU type in executable" and waste time.
        let version: String?
        if archs.contains(HostArchitecture.current.machOArchName) {
            version = await Self.runVersion(at: url)
        } else {
            version = nil
        }
        let signatureValid = await Self.checkSignature(at: url)
        return NaiveBinaryDescriptor(
            url: url,
            origin: origin,
            architectures: archs,
            version: version,
            isCodeSignatureValid: signatureValid
        )
    }

    /// Path to the naive binary inside the running app bundle's
    /// `Contents/Resources/` directory.
    public static func bundledURL() -> URL {
        Bundle.main.url(forResource: "naive", withExtension: nil)
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/naive")
    }

    // MARK: - Subprocess helpers

    /// Parses `lipo -info <path>` output into a set of arch names.
    /// Tolerant of both `Non-fat file: … is architecture: arm64` and
    /// `Architectures in the fat file: … are: x86_64 arm64`.
    private static func runLipoInfo(at url: URL) async -> Set<String> {
        let result = await runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/lipo"),
            arguments: ["-info", url.path]
        )
        guard let output = result, !output.isEmpty else { return [] }

        // `lipo -info` puts the arch list after the last colon on the
        // line. Splitting on ":" and trimming gives us "arm64 x86_64"
        // for fat files and "arm64" for thin ones.
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
        // Filter to the slice names we know about. This protects the UI
        // from printing junk if a future `lipo` adds extra annotations.
        let known: Set<String> = ["arm64", "arm64e", "x86_64", "i386"]
        return Set(tokens.filter { known.contains($0) })
    }

    /// Runs the candidate with `--version` and returns the first line of
    /// output, or `nil` if the binary does not understand the flag.
    private static func runVersion(at url: URL) async -> String? {
        // Some naive builds emit version on stdout, others on stderr —
        // we capture both and return whichever yields a non-empty line
        // first.
        let output = await runProcess(
            executable: url,
            arguments: ["--version"]
        )
        return output?
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)
    }

    /// Returns whether [`CodeSignVerifier`] accepts the binary. Errors
    /// are swallowed because the descriptor stores the boolean; callers
    /// re-run the verifier to extract the OSStatus when they need a
    /// typed error.
    private static func checkSignature(at url: URL) async -> Bool {
        do {
            try await CodeSignVerifier.verifyValid(at: url)
            return true
        } catch {
            return false
        }
    }

    /// Generic subprocess runner: collects stdout+stderr into one string,
    /// returns `nil` if the process could not be launched at all. We
    /// intentionally tolerate non-zero exit codes — `naive --version`
    /// historically exits 0, but even a non-zero exit accompanied by a
    /// version line is still informative for the UI.
    private static func runProcess(
        executable: URL,
        arguments: [String]
    ) async -> String? {
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
