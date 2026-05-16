// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
// SystemIntegration/NaiveUpdater.swift
//
// Downloads the latest upstream NaiveProxy macOS build (arm64 + x64),
// lipo-merges the two slices into one universal Mach-O, ad-hoc signs
// it, and drops it into `~/Library/Application Support/COOL-TUNNEL/
// naive-managed` so the orchestrator can adopt it as a custom binary
// path. Mirrors `scripts/fetch_naive.sh` but lives in-app so the
// Settings "Update naive" button works on an installed `.app`
// (where bundled `Contents/Resources/naive` is read-only and re-
// signing it would invalidate the app's own signature).
//
// **v2.0.51 consolidation:** the shared mechanics (download
// wrapper with host-trust + size-cap error mapping, atomic
// install, ad-hoc sign, subprocess helper, tag-vs-binary
// comparison, GitHub API fetch boilerplate, lastInstalledTag
// self-heal) live in `BinaryUpdater.swift` alongside the
// matching extractions out of `RustCoreUpdater`. This file
// keeps the naive-specific state machine + lipo / extract
// pipeline steps that the Rust core has no counterpart for.

import Foundation
import Observation
import os

private let naiveUpdaterLogger = Logger.cooltunnel("NaiveUpdater")

@MainActor
@Observable
final class NaiveUpdater {

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
        key: "NaiveUpdater.lastInstalledTag")
    private let supportDirectory: URL

    init(supportDirectory: URL) {
        self.supportDirectory = supportDirectory
    }

    convenience init(paths: AppSupportPaths) {
        self.init(supportDirectory: paths.supportDirectory)
    }

    var installedURL: URL {
        supportDirectory.appendingPathComponent(
            "naive-managed", isDirectory: false)
    }

    /// **v2.0.2:** query upstream for the latest stable tag and
    /// compare against the installed binary. Caller passes the
    /// binary's `--version` line so cosmetic upstream `-N` patch
    /// suffixes don't trip a redundant download. Re-running while
    /// a previous run is in flight is a no-op so the state machine
    /// stays monotonic.
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
            // path: GitHub release tags are typically `vN.N.N-N`
            // but the API returns whatever upstream pushed, and
            // characters like `..`, spaces, `?`, `#`, `/` would
            // produce a URL pointing outside the intended release
            // directory.
            guard updaterIsValidReleaseTag(tag) else {
                throw UpdaterError.message(
                    "GitHub returned an unexpected release tag (\(tag)). Refusing to download — check upstream and try again."
                )
            }

            let tempRoot = try BinaryUpdaterCore.makeTempDirectory(
                prefix: "cool-tunnel-naive-update")
            // try-ok: defer-block tempdir teardown
            defer { try? FileManager.default.removeItem(at: tempRoot) }

            // Both arches in parallel — network-bound, no CPU
            // contention.
            state = .downloading(progress: 0.0)
            let arm64URL = try Self.assetURL(tag: tag, arch: .arm64)
            let x64URL = try Self.assetURL(tag: tag, arch: .x64)
            async let arm64Tarball = BinaryUpdaterCore.download(
                url: arm64URL,
                to: tempRoot.appendingPathComponent("arm64.tar.xz"),
                logger: naiveUpdaterLogger
            )
            async let x64Tarball = BinaryUpdaterCore.download(
                url: x64URL,
                to: tempRoot.appendingPathComponent("x64.tar.xz"),
                logger: naiveUpdaterLogger
            )
            let arm64Path = try await arm64Tarball
            let x64Path = try await x64Tarball
            state = .downloading(progress: 1.0)

            state = .extracting
            async let arm64BinAsync = Self.extractNaive(
                from: arm64Path,
                into: tempRoot.appendingPathComponent("arm64"))
            async let x64BinAsync = Self.extractNaive(
                from: x64Path,
                into: tempRoot.appendingPathComponent("x64"))
            let arm64Bin = try await arm64BinAsync
            let x64Bin = try await x64BinAsync

            state = .merging
            let merged = tempRoot.appendingPathComponent("naive-universal")
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

    // MARK: - Naive-specific pipeline steps (off-main)

    private enum Arch { case arm64, x64 }

    private static func assetURL(tag: String, arch: Arch) throws -> URL {
        let archToken = arch == .arm64 ? "arm64-arm64" : "x64-x64"
        let asset = "naiveproxy-\(tag)-mac-\(archToken).tar.xz"
        let urlString =
            "https://github.com/klzgrad/naiveproxy/releases/download/\(tag)/\(asset)"
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
                    "https://api.github.com/repos/klzgrad/naiveproxy/releases?per_page=20"
            )
        else {
            throw UpdaterError.message(
                "internal error: invalid hardcoded GitHub API URL")
        }
        let data = try await BinaryUpdaterCore.fetchReleaseJSON(
            apiURL: apiURL, apiKind: "NaiveProxy")
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
            throw UpdaterError.message("no NaiveProxy releases found upstream")
        }
        return stable.tagName
    }

    /// Extracts a `.tar.xz` and returns the path to the inner
    /// `naive` binary (strips the leading single-component dir).
    nonisolated private static func extractNaive(
        from archive: URL, into target: URL
    ) async throws -> URL {
        try FileManager.default.createDirectory(
            at: target, withIntermediateDirectories: true)
        try await BinaryUpdaterCore.runProcess(
            executable: "/usr/bin/tar",
            arguments: [
                "-xJf", archive.path, "-C", target.path,
                "--strip-components=1",
            ]
        )
        let binary = target.appendingPathComponent("naive")
        guard FileManager.default.fileExists(atPath: binary.path) else {
            throw UpdaterError.message(
                "The downloaded NaiveProxy archive looked incomplete. Try Update again — the previous download was probably interrupted."
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
