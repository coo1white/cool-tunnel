// SystemIntegration/AppSupportPaths.swift
//
// Resolves the paths the app reads from and writes to. Centralising them
// keeps the "where do these files live" knowledge in one place.

import Darwin
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

    /// Writes `data` to `url` atomically with 0600 permissions
    /// established **before** the rename. The previous
    /// implementation used `Data.write(.atomic)` (which writes a
    /// temp file at the umask default — typically 0644 — then
    /// renames) followed by `setAttributes` to 0600. That left a
    /// race window where the file was on disk world-readable; if
    /// the process crashed or hit ENOSPC between rename and
    /// chmod, the credential file persisted at 0644.
    ///
    /// New flow: open a sibling `.tmp` file with `O_CREAT|O_EXCL`
    /// and explicit `0600`, write all bytes, fsync, then rename.
    /// `0600` is established at creation time; the rename is
    /// atomic; no chmod-after-rename race exists.
    public static func write(_ data: Data, to url: URL) throws {
        let parent = url.deletingLastPathComponent().path
        // Use a randomised temp filename in the same directory so
        // `rename(2)` stays on the same filesystem (atomic) and so
        // a concurrent writer to the same destination doesn't
        // collide on a fixed name.
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(tempURL.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }
        do {
            // Write the full buffer; partial writes get retried.
            try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress else { return }
                var remaining = raw.count
                var cursor = base
                while remaining > 0 {
                    let written = Darwin.write(fd, cursor, remaining)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
                    }
                    if written == 0 { break }
                    remaining -= written
                    cursor = cursor.advanced(by: written)
                }
            }
            // fsync so a crash before journal flush doesn't leave
            // the rename pointing at empty/partial bytes on disk.
            _ = fsync(fd)
            close(fd)
            // rename(2) is atomic on the same filesystem. Any
            // existing file at `url` is replaced atomically.
            if rename(tempURL.path, url.path) != 0 {
                let renameErrno = errno
                _ = unlink(tempURL.path)
                throw POSIXError(POSIXError.Code(rawValue: renameErrno) ?? .EIO)
            }
        } catch {
            close(fd)
            _ = unlink(tempURL.path)
            throw error
        }
        // Touch the parent directory's mtime so directory-watching
        // tools see the change. Not load-bearing; ignore failure.
        _ = utimes(parent, nil)
    }

    /// UTF-8 string convenience over [`write(_:to:)`].
    public static func write(_ text: String, to url: URL) throws {
        guard let data = text.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try write(data, to: url)
    }
}
