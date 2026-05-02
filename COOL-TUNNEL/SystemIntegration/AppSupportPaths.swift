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
}

/// Convenience helper that writes `data` to `url` with `0600` permissions
/// (user read/write only) — the same posture the previous Swift code used
/// for the credential-bearing config file.
public func writeRestrictedFile(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: url.path
    )
}

/// Same as [`writeRestrictedFile`] but for UTF-8 string content.
public func writeRestrictedFile(_ text: String, to url: URL) throws {
    guard let data = text.data(using: .utf8) else {
        throw CocoaError(.fileWriteInapplicableStringEncoding)
    }
    try writeRestrictedFile(data, to: url)
}
