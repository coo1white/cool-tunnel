// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
// SystemIntegration/SingboxUpdater.swift
//
// Downloads the latest upstream sing-box macOS build (arm64 + x64),
// lipo-merges the two slices into one universal Mach-O, ad-hoc signs
// it, and drops it into `~/Library/Application Support/COOL-TUNNEL/
// singbox-managed` so the orchestrator can adopt it as a custom binary
// path. Mirrors `scripts/fetch_singbox-core.ts` but lives in-app so
// the Settings "Update sing-box" button works on an installed `.app`
// (where the bundled `Contents/Resources/sing-box` is read-only and
// re-signing it would invalidate the app's own signature).
//
// **v3.0.0:** renamed from `NaiveUpdater`. The download target moved
// from `klzgrad/naiveproxy` (HTTP/2 basic-auth) to `SagerNet/sing-box`
// (VLESS+Reality). The asset shape changed from
// `naiveproxy-<tag>-mac-<arch>.tar.xz` to
// `sing-box-<stem>-darwin-<arch>.tar.gz` (gzip, not xz; `darwin-amd64`
// not `mac-x64-x64`). The internal tarball binary is now `sing-box`
// instead of `naive`.
//
// **v2.0.51 consolidation (preserved):** the shared mechanics
// (download wrapper with host-trust + size-cap error mapping,
// atomic install, ad-hoc sign, subprocess helper, tag-vs-binary
// comparison, GitHub API fetch boilerplate, lastInstalledTag
// self-heal) live in `BinaryUpdater.swift` alongside the matching
// extractions out of `RustCoreUpdater`. This file keeps the
// singbox-specific state machine + lipo / extract pipeline steps
// that the Rust core has no counterpart for.

import Foundation
import Observation
import os

private let singboxUpdaterLogger = Logger.cooltunnel("SingboxUpdater")

@MainActor
@Observable
final class SingboxUpdater {

    /// What the updater is doing right now. **v2.0.2:** `checking`
    /// / `upToDate` / `available` mirror AppUpdater's check-then-
    /// update pattern; pre-2.0.2 `update()` always re-downloaded.
    /// `SettingsView` literal-matches every case below.
    enum State: Sendable, Equatable {
        case idle
        case checking
        case upToDate(currentVersion: String, latestTag: String)
        case available(tag: String, currentVersion: String)
        case resolvingTag
        case downloading(progress: Double)  // 0.0 – 1.0
        case extracting
        case merging
        case installing
        case succeeded(tag: String, installedPath: URL)
        case failed(message: String)
    }

    private(set) var state: State = .idle
    var lastInstalledTag: String? { tagStore.value }

    private let tagStore = UpdaterTagStore(
        key: "SingboxUpdater.lastInstalledTag")
    private let supportDirectory: URL

    init(supportDirectory: URL) {
        self.supportDirectory = supportDirectory
    }

    convenience init(paths: AppSupportPaths) {
        self.init(supportDirectory: paths.supportDirectory)
    }

    var installedURL: URL {
        supportDirectory.appendingPathComponent(
            "singbox-managed", isDirectory: false)
    }

    /// **v2.0.2:** query upstream for the latest stable tag and
    /// compare against the installed binary. Caller passes the
    /// binary's `version` line so cosmetic upstream patch suffixes
    /// don't trip a redundant download. Re-running while a previous
    /// run is in flight is a no-op so the state machine stays
    /// monotonic.
    func checkForUpdates(currentVersion: String) async {
        guard !isBusy else { return }
        // **v2.0.27 hotfix (parity with v2.0.24's RustCoreUpdater
        // self-heal):** clear stale persisted tag if the managed
        // binary is gone. See `UpdaterTagStore.selfHealIfMissing`.
        tagStore.selfHealIfMissing(installedAt: installedURL)
        state = .checking
        do {
            let tag = try await Self.resolveLatestStableTag()
            guard updaterIsValidReleaseTag(tag) else {
                throw UpdaterError.message(
                    "GitHub returned an unexpected release tag (\(tag)). Refusing to proceed."
                )
            }
            if updaterTagIsConsideredCurrent(
                tag,
                forBinaryVersion: currentVersion,
                lastInstalled: lastInstalledTag
            ) {
                state = .upToDate(
                    currentVersion: currentVersion, latestTag: tag)
            } else {
                state = .available(
                    tag: tag, currentVersion: currentVersion)
            }
        } catch UpdaterError.message(let reason) {
            state = .failed(message: reason)
        } catch {
            state = .failed(message: error.localizedDescription)
        }
    }

    @discardableResult
    func update() async -> URL? {
        guard !isBusy else { return nil }

        // **v2.0.2:** reuse the tag the preceding check just
        // resolved instead of re-fetching `/releases`.
        let preResolvedTag: String?
        if case .available(let tag, _) = state {
            preResolvedTag = tag
        } else {
            preResolvedTag = nil
        }

        do {
            let tag: String
            if let preResolvedTag {
                tag = preResolvedTag
            } else {
                state = .resolvingTag
                tag = try await Self.resolveLatestStableTag()
            }
            // Defence in depth before interpolating into a URL
            // path: GitHub release tags are typically `vN.N.N` but
            // the API returns whatever upstream pushed, and
            // characters like `..`, spaces, `?`, `#`, `/` would
            // produce a URL pointing outside the intended release
            // directory.
            guard updaterIsValidReleaseTag(tag) else {
                throw UpdaterError.message(
                    "GitHub returned an unexpected release tag (\(tag)). Refusing to download — check upstream and try again."
                )
            }

            let tempRoot = try BinaryUpdaterCore.makeTempDirectory(
                prefix: "cool-tunnel-singbox-update")
            // try-ok: defer-block tempdir teardown
            defer { try? FileManager.default.removeItem(at: tempRoot) }

            // Both arches in parallel — network-bound, no CPU
            // contention.
            state = .downloading(progress: 0.0)
            let arm64URL = try Self.assetURL(tag: tag, arch: .arm64)
            let x64URL = try Self.assetURL(tag: tag, arch: .x64)
            async let arm64Tarball = BinaryUpdaterCore.download(
                url: arm64URL,
                to: tempRoot.appendingPathComponent("arm64.tar.gz"),
                logger: singboxUpdaterLogger
            )
            async let x64Tarball = BinaryUpdaterCore.download(
                url: x64URL,
                to: tempRoot.appendingPathComponent("x64.tar.gz"),
                logger: singboxUpdaterLogger
            )
            let arm64Path = try await arm64Tarball
            let x64Path = try await x64Tarball
            state = .downloading(progress: 1.0)

            state = .extracting
            async let arm64BinAsync = Self.extractSingbox(
                from: arm64Path,
                into: tempRoot.appendingPathComponent("arm64"))
            async let x64BinAsync = Self.extractSingbox(
                from: x64Path,
                into: tempRoot.appendingPathComponent("x64"))
            let arm64Bin = try await arm64BinAsync
            let x64Bin = try await x64BinAsync

            state = .merging
            let merged = tempRoot.appendingPathComponent("sing-box-universal")
            try await Self.lipoCreate(
                arm64: arm64Bin, x64: x64Bin, output: merged)
            try await BinaryUpdaterCore.adhocSign(at: merged)

            state = .installing
            try BinaryUpdaterCore.atomicallyInstall(
                from: merged, to: installedURL)

            tagStore.value = tag
            state = .succeeded(tag: tag, installedPath: installedURL)
            return installedURL
        } catch UpdaterError.message(let reason) {
            state = .failed(message: reason)
            return nil
        } catch {
            state = .failed(message: error.localizedDescription)
            return nil
        }
    }

    func reset() {
        guard !isBusy else { return }
        state = .idle
    }

    private var isBusy: Bool {
        switch state {
        case .checking, .resolvingTag, .downloading, .extracting,
            .merging, .installing:
            return true
        default:
            return false
        }
    }

    // MARK: - sing-box-specific pipeline steps (off-main)

    private enum Arch { case arm64, x64 }

    /// Strip the leading `v` from a release tag for the asset
    /// filename. Upstream tags are `vX.Y.Z`; release assets are
    /// `sing-box-X.Y.Z-darwin-<arch>.tar.gz`. Mirrors the
    /// `tagToAssetStem` helper in `scripts/fetch_singbox-core.ts`.
    private static func tagToAssetStem(_ tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    private static func assetURL(tag: String, arch: Arch) throws -> URL {
        let stem = tagToAssetStem(tag)
        let archToken = arch == .arm64 ? "arm64" : "amd64"
        let asset = "sing-box-\(stem)-darwin-\(archToken).tar.gz"
        let urlString =
            "https://github.com/SagerNet/sing-box/releases/download/\(tag)/\(asset)"
        // Thrown error rather than `fatalError` so a future
        // interpolation bug surfaces as a friendly UI error
        // rather than a process crash.
        guard let url = URL(string: urlString) else {
            throw UpdaterError.message(
                "internal error: constructed invalid release URL: \(urlString)"
            )
        }
        // **R-F#4:** defence-in-depth HTTPS + GitHub-host check
        // on the constructed URL. Belt-and-braces today since
        // the template is hardcoded; aligns with AppUpdater AU-2.
        guard isTrustedGitHubURL(url) else {
            throw UpdaterError.message(
                "internal error: release URL is not on a trusted GitHub host: \(urlString)"
            )
        }
        return url
    }

    /// Hits `/releases` and picks the highest-priority stable
    /// (non-prerelease) tag. Used instead of `/releases/latest`
    /// because upstream sometimes flips that endpoint to
    /// pre-release tags.
    private static func resolveLatestStableTag() async throws -> String {
        guard
            let apiURL = URL(
                string:
                    "https://api.github.com/repos/SagerNet/sing-box/releases?per_page=20"
            )
        else {
            throw UpdaterError.message(
                "internal error: invalid hardcoded GitHub API URL")
        }
        let data = try await BinaryUpdaterCore.fetchReleaseJSON(
            apiURL: apiURL, apiKind: "sing-box")
        struct Release: Decodable {
            let tagName: String
            let prerelease: Bool
            enum CodingKeys: String, CodingKey {
                case tagName = "tag_name"
                case prerelease
            }
        }
        let releases = try JSONDecoder().decode([Release].self, from: data)
        guard
            let stable = releases.first(where: { !$0.prerelease })
                ?? releases.first
        else {
            throw UpdaterError.message("no sing-box releases found upstream")
        }
        return stable.tagName
    }

    /// Extracts a `.tar.gz` and returns the path to the inner
    /// `sing-box` binary (strips the leading single-component dir).
    nonisolated private static func extractSingbox(
        from archive: URL, into target: URL
    ) async throws -> URL {
        try FileManager.default.createDirectory(
            at: target, withIntermediateDirectories: true)
        // sing-box ships gzip-compressed tarballs (.tar.gz), so -z
        // (not -J like the v2.x naive .tar.xz path used).
        // --strip-components=1 drops the leading
        // `sing-box-<stem>-darwin-<arch>/` directory.
        try await BinaryUpdaterCore.runProcess(
            executable: "/usr/bin/tar",
            arguments: [
                "-xzf", archive.path, "-C", target.path,
                "--strip-components=1",
            ]
        )
        let binary = target.appendingPathComponent("sing-box")
        guard FileManager.default.fileExists(atPath: binary.path) else {
            throw UpdaterError.message(
                "The downloaded sing-box archive looked incomplete. Try Update again — the previous download was probably interrupted."
            )
        }
        return binary
    }

    nonisolated private static func lipoCreate(
        arm64: URL, x64: URL, output: URL
    ) async throws {
        try await BinaryUpdaterCore.runProcess(
            executable: "/usr/bin/lipo",
            arguments: [
                "-create", arm64.path, x64.path, "-output", output.path,
            ]
        )
    }
}
