// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
// SystemIntegration/ProxyActiveFlag.swift
//
// **Lifecycle-F#16 (v0.1.7.18):** sentinel file for system-proxy
// crash recovery.
//
// The problem: when Cool Tunnel enables the system proxy
// (`networksetup -setsocksfirewallproxy` / `-setautoproxystate`)
// the macOS network preferences carry that state across reboots.
// If Cool Tunnel crashes (`SIGKILL`, kernel panic, abrupt power
// loss) without the chance to call `disableAll()`, the system
// proxy stays enabled — pointing at `127.0.0.1:1080` where
// nothing is listening. Result: every browser request stalls
// until the user manually opens System Settings → Network →
// Proxies and unticks the boxes.
//
// The fix: at the moment of enabling system proxy, write a tiny
// JSON sentinel to `~/Library/Application Support/COOL-TUNNEL/
// proxy-active.flag`. On clean disable, delete it. On every
// app launch (before any other startup work), check if the
// flag exists; if it does, the previous run crashed with proxy
// enabled — force `disableAll()` immediately, then delete the
// flag so the user gets back into a working state with no
// manual recovery.
//
// This design deliberately does NOT try to "restore the user's
// previous proxy settings." That would require parsing
// `networksetup -getsocksfirewallproxy` per-service output,
// which is brittle across macOS versions and adds complexity
// for a corner case (most Cool Tunnel users aren't running a
// second proxy tool simultaneously). Force-off is the safer
// default; users who DO have a second proxy can re-enable it
// in System Settings, which is the same recovery path they'd
// have without this fix.

import Foundation
import os

/// Manages the proxy-active sentinel file. All operations are
/// best-effort — failure to write the flag should never block
/// the proxy from coming up; failure to read on bootstrap
/// should never block the app from launching.
public enum ProxyActiveFlag {

    private static let logger = Logger.cooltunnel("ProxyRecovery")

    /// Path to the sentinel file. Lives next to credentials in
    /// the same restricted-permissions Application Support dir.
    public static func path(in supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent(
            "proxy-active.flag", isDirectory: false)
    }

    /// JSON payload of the sentinel. `version` is for forward
    /// compatibility — if v0.2 wants to record per-service state
    /// for full restore, it bumps the version and old readers
    /// (this code) ignore the unknown shape.
    private struct Payload: Codable {
        let version: Int
        let enabledAt: Date
        let mode: String
    }

    /// Writes the sentinel. Called by the orchestrator at the
    /// moment system proxy is enabled.
    public static func write(at path: URL, mode: String) {
        let payload = Payload(
            version: 1,
            enabledAt: Date(),
            mode: mode
        )
        do {
            let data = try JSONEncoder().encode(payload)
            try data.write(to: path, options: [.atomic])
            logger.info("proxy-active flag written: mode=\(mode, privacy: .public)")
        } catch {
            // Logging only — flag-write failure must not block
            // the proxy from coming up. Users with a wedged disk
            // will see the proxy-stuck-on bug recur, but they
            // would have seen it pre-fix too.
            logger.warning(
                "failed to write proxy-active flag: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Removes the sentinel. Called on clean disable.
    /// Idempotent — missing-file is success.
    public static func clear(at path: URL) {
        do {
            try FileManager.default.removeItem(at: path)
            logger.info("proxy-active flag cleared")
        } catch CocoaError.fileNoSuchFile {
            // Already gone — fine.
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain
            && error.code == NSFileNoSuchFileError
        {
            // Same. Older Swift bridges raise the NSError variant.
        } catch {
            logger.warning(
                "failed to clear proxy-active flag: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Returns true if the sentinel exists, indicating the
    /// previous run did not cleanly disable the proxy. Caller
    /// should immediately force-disable then `clear()`.
    public static func existsIndicatingCrash(at path: URL) -> Bool {
        FileManager.default.fileExists(atPath: path.path)
    }

    /// Convenience: read the sentinel payload for diagnostics
    /// (e.g. to log "previous run crashed in mode=Smart at
    /// timestamp X"). Returns nil on missing/unreadable file.
    public static func readPayload(at path: URL) -> (mode: String, enabledAt: Date)? {
        guard let data = try? Data(contentsOf: path),
            let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else {
            return nil
        }
        return (payload.mode, payload.enabledAt)
    }
}
