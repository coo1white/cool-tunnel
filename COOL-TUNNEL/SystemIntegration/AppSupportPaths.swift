// SystemIntegration/AppSupportPaths.swift
//
// Resolves the paths the app reads from and writes to. Centralising them
// keeps the "where do these files live" knowledge in one place.

import Foundation

/// Filesystem locations the app uses.
public struct AppSupportPaths: Sendable {

    /// `~/Library/Application Support/COOL-TUNNEL`.
    public let supportDirectory: URL
    /// JSON config path the engine hands to the bundled `naive` binary.
    public let configFile: URL
    /// Smart-routing PAC file path referenced by `networksetup`.
    public let pacFile: URL

    public init() throws {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let support = base.appendingPathComponent("COOL-TUNNEL", isDirectory: true)
        try FileManager.default.createDirectory(
            at: support,
            withIntermediateDirectories: true
        )
        // Tighten permissions to 0700. The parent (~/Library/Application Support)
        // already restricts to the user, but defence-in-depth — if anything
        // ever loosens the parent, this directory keeps its config.json
        // (which used to contain credentials before the Keychain migration,
        // and still contains the proxy URL) out of reach for other users.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: support.path
        )
        self.supportDirectory = support
        self.configFile = support.appendingPathComponent("config.json", isDirectory: false)
        self.pacFile = support.appendingPathComponent("smart-proxy.pac", isDirectory: false)
    }

    /// Memberwise initialiser used by [`fallback`] when the real
    /// Application Support directory cannot be created. Kept
    /// `internal` so production code goes through `init()`.
    init(supportDirectory: URL, configFile: URL, pacFile: URL) {
        self.supportDirectory = supportDirectory
        self.configFile = configFile
        self.pacFile = pacFile
    }

    /// Degraded-mode paths rooted in a per-process temporary
    /// directory. Used by `TunnelOrchestrator.bootstrap()` when the
    /// real Application Support path cannot be created — the
    /// orchestrator records the original failure as `lastError`
    /// and the user sees a real error rather than a `fatalError`
    /// crash. Subsequent operations against these paths will still
    /// fail (config writes, etc.), but each failure has a real
    /// surface in the UI instead of a launch crash.
    public static func fallback() -> AppSupportPaths {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("COOL-TUNNEL-fallback", isDirectory: true)
        return AppSupportPaths(
            supportDirectory: tmp,
            configFile: tmp.appendingPathComponent("config.json", isDirectory: false),
            pacFile: tmp.appendingPathComponent("smart-proxy.pac", isDirectory: false)
        )
    }
}

/// Atomic file writes with 0600 permissions (user-only
/// read/write) — the same posture the previous Swift code used
/// for credential-bearing config files. Namespaced as a
/// caseless enum so the helpers don't pollute module-global
/// space; the rest of the codebase calls them as
/// `RestrictedFile.write(...)`.
public enum RestrictedFile {

    /// Writes `data` to `url` atomically and tightens permissions
    /// to 0600.
    public static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    /// UTF-8 string convenience over [`write(_:to:)`].
    public static func write(_ text: String, to url: URL) throws {
        guard let data = text.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try write(data, to: url)
    }
}
