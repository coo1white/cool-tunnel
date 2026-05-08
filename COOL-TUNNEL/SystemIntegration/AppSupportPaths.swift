// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
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
        // Exclude the entire support tree from Time Machine.
        // `config.json` carries the cleartext `https://user:pass@host`
        // proxy URL, and `credentials.json` (written by
        // `FileCredentialStore`) carries base64-encoded passwords;
        // both are 0600 user-only on disk but Time Machine snapshots
        // are accessible to the next administrator who restores the
        // user's home folder. Setting `isExcludedFromBackupKey`
        // on the directory covers every file inside it now and in
        // the future. The call is idempotent — re-running on every
        // launch corrects a backup state that drifted (e.g. user
        // restored from a pre-flag backup).
        var supportMutable = support
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try? supportMutable.setResourceValues(resources)
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
    /// **v0.1.7.13 (R-F#1):** added `mode` parameter so callers
    /// that need a different POSIX mode (e.g. an executable
    /// helper script at `0o700`) can reuse the atomic
    /// `O_CREAT|O_EXCL` + write + fsync + rename primitive
    /// instead of reimplementing it. Default `0o600` preserves
    /// the credentials-file behaviour every existing caller
    /// expects.
    public static func write(_ data: Data, to url: URL, mode: mode_t = 0o600) throws {
        let parent = url.deletingLastPathComponent().path
        // Use a randomised temp filename in the same directory so
        // `rename(2)` stays on the same filesystem (atomic) and so
        // a concurrent writer to the same destination doesn't
        // collide on a fixed name.
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(tempURL.path, O_WRONLY | O_CREAT | O_EXCL, mode)
        guard fd >= 0 else {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }
        // **SEC-F#6 (v0.1.7.15):** belt-and-braces `fchmod` to
        // defeat umask interaction. `open(2)`'s mode arg is
        // ANDed with `~umask` per POSIX; on a system with an
        // unusual umask (corporate-managed `umask 077`, or a
        // future caller passing `0o755`) the file would be
        // created with FEWER permissions than requested.
        // `fchmod(2)` doesn't honour umask, so this guarantees
        // the file ends up at exactly `mode`. For the existing
        // call sites (credentials at 0o600, relaunch script at
        // 0o700) the umask interaction was a no-op, but locking
        // the contract here means future callers can rely on
        // the requested mode without auditing their environment.
        if fchmod(fd, mode) != 0 {
            let chmodErrno = errno
            close(fd)
            _ = unlink(tempURL.path)
            throw POSIXError(POSIXError.Code(rawValue: chmodErrno) ?? .EIO)
        }
        // Track close state so the catch block doesn't double-close
        // a fd we already closed in the success path. macOS may
        // reuse a closed fd for an unrelated open() between
        // close() and the catch — closing it twice would corrupt
        // an unrelated file handle in this process. v0.1.7.10 fix.
        var didClose = false
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
            // **v0.1.7.10 fix:** check the return value. The
            // previous `_ = fsync(fd)` swallowed EIO, meaning a
            // disk-level write failure on flush would silently
            // proceed to rename — yielding an "atomic" write
            // pointing at unflushed bytes. A crash right after
            // the rename would leave an empty/partial
            // credentials.json that decodes as `.malformed` and
            // locks the user out of saved passwords.
            if fsync(fd) != 0 {
                let fsyncErrno = errno
                close(fd)
                didClose = true
                _ = unlink(tempURL.path)
                throw POSIXError(POSIXError.Code(rawValue: fsyncErrno) ?? .EIO)
            }
            close(fd)
            didClose = true
            // rename(2) is atomic on the same filesystem. Capture
            // errno on the SAME line as the syscall — anything
            // between rename and the read could clobber it.
            let renameOK = rename(tempURL.path, url.path) == 0
            let renameErrno = errno
            if !renameOK {
                _ = unlink(tempURL.path)
                throw POSIXError(POSIXError.Code(rawValue: renameErrno) ?? .EIO)
            }
        } catch {
            if !didClose { close(fd) }
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
