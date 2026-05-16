// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
// SystemIntegration/BinaryUpdater.swift
//
// Shared mechanics for `NaiveUpdater` and `RustCoreUpdater`.
// Both follow the same outer shape: GET `/releases` JSON, pick
// a release, resolve asset URL(s), download into a temp dir
// (host-validated, redirect-guarded, size-capped via
// `GitHubRedirectGuard`), run a per-updater verification +
// prepare step (lipo + ad-hoc sign for naive; SHA-256 pin +
// ad-hoc sign for rust), atomically install into Application
// Support, stamp `lastInstalledTag` (UserDefaults).
//
// Before v2.0.51 these mechanics lived twice — diverging
// slowly (the v2.0.27 self-heal in `NaiveUpdater.checkForUpdates`
// was lifted from the v2.0.24 RustCoreUpdater self-heal three
// releases earlier; `runProcess`, `atomicallyInstall`,
// `tagIsConsideredCurrent`, the host-trusted download wrapper,
// and the GitHub API request boilerplate were already
// byte-identical). Consolidating removes the recurring "fix
// landed in one updater, slipped in the other" pattern.
//
// The two updaters keep their own `@Observable` classes
// because their `State` enums differ — `.resolvingTag` vs
// `.resolvingRelease`, plus `.extracting`/`.merging` for naive
// only — and `SettingsView` exhaustively switches on those
// literal case names.

import Foundation
import os

// MARK: - Shared helpers

/// True if `tag` represents a build the user is already on.
/// Two paths qualify: exact match against the persisted
/// `lastInstalledTag`, or binary-semver match (strip `v` prefix
/// and `-N` patch suffix from the tag, compare to the bare
/// semver in the binary's `--version` last whitespace token).
/// The latter catches upstream's cosmetic `-N` re-tags that
/// rebuild the same source.
func updaterTagIsConsideredCurrent(
    _ tag: String,
    forBinaryVersion binaryVersion: String,
    lastInstalled: String?
) -> Bool {
    if let lastInstalled, lastInstalled == tag {
        return true
    }
    let stripV = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    let tagSemver =
        stripV.components(separatedBy: "-").first ?? stripV
    let binarySemver =
        binaryVersion
        .split(whereSeparator: \.isWhitespace).last
        .map(String.init) ?? binaryVersion
    return !tagSemver.isEmpty && tagSemver == binarySemver
}

/// Whether `tag` matches the canonical release-tag shape used
/// by NaiveProxy + cool-tunnel: `v` + 1-4 numeric segments +
/// optional `-N` suffix. Defence in depth before URL
/// interpolation — characters like `..`, spaces, `?`, `#`, `/`
/// would produce a URL pointing outside the release directory.
func updaterIsValidReleaseTag(_ tag: String) -> Bool {
    guard !tag.isEmpty, tag.count <= 64 else { return false }
    let pattern = #"^v?\d+(\.\d+){0,3}(-[A-Za-z0-9.]+)?$"#
    return tag.range(of: pattern, options: .regularExpression) != nil
}

// MARK: - BinaryUpdaterCore

/// I/O primitives shared by `NaiveUpdater` and `RustCoreUpdater`.
/// Everything `nonisolated` so the updaters' `@MainActor`
/// orchestrators can call them from `Task.detached` blocks.
enum BinaryUpdaterCore {

    /// Per-pipeline temp dir under `NSTemporaryDirectory()`.
    /// Caller is responsible for removing it in a `defer` cleanup.
    static func makeTempDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }

    /// Wraps `GitHubRedirectGuard.download` with the user-facing
    /// error translation both updaters need. Logs technical detail
    /// (host, size, NSError description) through `logger`; the
    /// `UpdaterError.message` body is the non-leaky UI string.
    /// **OPSEC (post-v2.0.50):** rejected-host log lines carry
    /// the host only, never the full URL.
    nonisolated static func download(
        url: URL,
        to destination: URL,
        maxBytes: Int64 = 100 * 1024 * 1024,
        logger: Logger,
        userFacingAssetName: String? = nil
    ) async throws -> URL {
        do {
            return try await GitHubRedirectGuard.download(
                url: url, to: destination, maxBytes: maxBytes)
        } catch let untrusted as UntrustedGitHubHostError {
            let host = untrusted.url.host ?? "<unknown>"
            logger.error("untrusted host: \(host, privacy: .public)")
            throw UpdaterError.message(
                "Refusing to download from non-GitHub host.")
        } catch let oversize as OversizeDownloadError {
            logger.error(
                "oversize download: actual=\(oversize.actual, privacy: .public) cap=\(oversize.cap, privacy: .public)"
            )
            throw UpdaterError.message(
                "Download exceeded the size limit; refusing to install.")
        } catch {
            let assetLabel = userFacingAssetName ?? url.lastPathComponent
            logger.warning(
                "download failure for \(assetLabel, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            throw UpdaterError.message(
                "Couldn't download \(assetLabel). Check your internet connection and try Update again."
            )
        }
    }

    /// Atomic install: stage to `<destination>.new`, set 0755,
    /// `replaceItemAt` (or `moveItem` if no existing target).
    /// Avoids leaving a half-copied binary at the destination
    /// if the process is killed mid-copy.
    nonisolated static func atomicallyInstall(
        from source: URL, to destination: URL
    ) throws {
        let staged = destination.appendingPathExtension("new")
        if FileManager.default.fileExists(atPath: staged.path) {
            try FileManager.default.removeItem(at: staged)
        }
        try FileManager.default.copyItem(at: source, to: staged)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: staged.path)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(
                destination, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: destination)
        }
    }

    /// **CONC-F#1 (v0.1.7.15):** ad-hoc codesign helper used by
    /// both pipelines. Routes through `Subprocess.run` so the
    /// MainActor isn't blocked through the codesign duration.
    nonisolated static func adhocSign(at url: URL) async throws {
        try await runProcess(
            executable: "/usr/bin/codesign",
            arguments: [
                "--force", "--sign", "-", "--timestamp=none", url.path,
            ])
    }

    /// Async subprocess helper. 120 s timeout matches the
    /// per-updater value both used since v0.1.7.15.
    nonisolated static func runProcess(
        executable: String, arguments: [String]
    ) async throws {
        let result: SubprocessResult
        do {
            result = try await Subprocess.run(
                executable: URL(fileURLWithPath: executable),
                arguments: arguments, timeout: 120)
        } catch {
            throw UpdaterError.message(
                "could not launch \(executable): \(error.localizedDescription)"
            )
        }
        if result.timedOut {
            throw UpdaterError.message(
                "\(URL(fileURLWithPath: executable).lastPathComponent) did not finish within 120s — refusing to continue."
            )
        }
        guard result.success else {
            let stderr = result.stderr
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdaterError.message(
                "\(URL(fileURLWithPath: executable).lastPathComponent) exit \(result.exitCode): \(stderr)"
            )
        }
    }

    /// GETs a GitHub `/releases` JSON endpoint with the shared
    /// headers (`Accept: application/vnd.github+json`, the
    /// `Cool-Tunnel-Updater` UA, SEC-F#11 `Cache-Control: no-cache`)
    /// and the `GitHubRedirectGuard.shared` per-task delegate
    /// (R-F#4) constraining any HTTP redirect to trusted hosts.
    /// `apiKind` ("NaiveProxy" / "Cool Tunnel") goes into the
    /// user-facing error so support can read it.
    nonisolated static func fetchReleaseJSON(
        apiURL: URL, apiKind: String
    ) async throws -> Data {
        var request = URLRequest(url: apiURL)
        request.setValue(
            "application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(
            "Cool-Tunnel-Updater", forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(
                for: request, delegate: GitHubRedirectGuard.shared)
        } catch {
            throw UpdaterError.message(
                "Couldn't reach GitHub to look up the latest \(apiKind) release. Check your internet connection and try again."
            )
        }
        guard
            let http = response as? HTTPURLResponse,
            http.statusCode == 200
        else {
            throw UpdaterError.message(
                "Couldn't reach GitHub to look up the latest \(apiKind) release. Check your internet connection and try again."
            )
        }
        return data
    }
}

// MARK: - UpdaterTagStore

/// UserDefaults-backed persistence for each updater's
/// `lastInstalledTag` plus a self-heal that clears the
/// persisted tag if the managed binary at `installedURL` is
/// gone (deleted by user, lost in Application Support cleanup,
/// never installed on this Mac, fresh Mac with iCloud-synced
/// UserDefaults from a previous host). Without the self-heal
/// `updaterTagIsConsideredCurrent` returns true on the stale
/// tag and the panel says "You're on the latest version (X)"
/// while the binary is in fact missing — the contradictory
/// NG/OK shape RustCoreUpdater hit until 2.0.24 and
/// NaiveUpdater until 2.0.27.
@MainActor
final class UpdaterTagStore {
    private let key: String
    private var cached: String?

    init(key: String) {
        self.key = key
        self.cached = UserDefaults.standard.string(forKey: key)
    }

    var value: String? {
        get { cached }
        set {
            cached = newValue
            UserDefaults.standard.set(newValue, forKey: key)
        }
    }

    func selfHealIfMissing(installedAt installedURL: URL) {
        if !FileManager.default.fileExists(atPath: installedURL.path) {
            value = nil
        }
    }
}
