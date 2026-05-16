// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
// SystemIntegration/RustCoreUpdater.swift
//
// Downloads the latest `cool-tunnel-core` Mach-O from
// coo1white/cool-tunnel, SHA-256-verifies it against the
// release's manifest, ad-hoc signs it, and atomically installs
// into Application Support so the Settings → Rust Core →
// Update flow can refresh the engine without reinstalling the
// whole .app. The new binary takes effect on the next app
// launch (hot-swapping the long-lived JSON-over-stdio engine
// mid-session is out of scope).
//
// Why a separate updater (vs reusing NaiveUpdater): the naive
// updater downloads upstream tarballs and lipo-merges arm64 +
// x86_64 itself. The Rust core ships a pre-merged universal
// asset alongside the .dmg / .pkg / .zip, plus a SHA-256
// manifest to pin against. The shared mechanics (download with
// trust gate, atomic install, ad-hoc sign, subprocess helper,
// tag-vs-binary comparison, GitHub API fetch, lastInstalledTag
// self-heal) live in `BinaryUpdater.swift` since v2.0.51.

import Foundation
import Observation
import os

private let rustCoreUpdaterLogger = Logger.cooltunnel("RustCoreUpdater")

@MainActor
@Observable
final class RustCoreUpdater {

    /// `SettingsView` literal-matches every case below. Shape
    /// mirrors `NaiveUpdater.State` minus `.extracting / .merging`
    /// (no lipo step) and renames `.resolvingTag` → `.resolvingRelease`.
    enum State: Sendable, Equatable {
        case idle
        case checking
        case upToDate(currentVersion: String, latestTag: String)
        case available(tag: String, currentVersion: String)
        case resolvingRelease
        case downloading(progress: Double)
        case installing
        case succeeded(tag: String, installedPath: URL)
        case failed(message: String)
    }

    private(set) var state: State = .idle
    var lastInstalledTag: String? { tagStore.value }

    private let tagStore = UpdaterTagStore(
        key: "RustCoreUpdater.lastInstalledTag")
    private let supportDirectory: URL

    init(supportDirectory: URL) {
        self.supportDirectory = supportDirectory
    }

    convenience init(paths: AppSupportPaths) {
        self.init(supportDirectory: paths.supportDirectory)
    }

    var installedURL: URL {
        supportDirectory.appendingPathComponent(
            "cool-tunnel-core-managed", isDirectory: false)
    }

    func checkForUpdates(currentVersion: String) async {
        guard !isBusy else { return }
        // **v2.0.24 hotfix:** see `UpdaterTagStore.selfHealIfMissing`.
        tagStore.selfHealIfMissing(installedAt: installedURL)
        state = .checking
        do {
            let resolved = try await Self.resolveLatestAsset()
            if updaterTagIsConsideredCurrent(
                resolved.tag,
                forBinaryVersion: currentVersion,
                lastInstalled: lastInstalledTag
            ) {
                state = .upToDate(
                    currentVersion: currentVersion,
                    latestTag: resolved.tag)
            } else {
                state = .available(
                    tag: resolved.tag, currentVersion: currentVersion)
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

        // **v2.0.2 note:** we re-fetch `/releases` here even
        // though `checkForUpdates` just did. The full
        // `ResolvedAsset` (download URL + manifest URL + asset
        // filename) isn't in the observable State, so the only
        // cheap way to keep structural correctness is a fresh
        // resolve. One metadata GET; not a redundant binary
        // download.
        do {
            state = .resolvingRelease
            let resolved = try await Self.resolveLatestAsset()

            state = .downloading(progress: 0.0)
            let tempRoot = try BinaryUpdaterCore.makeTempDirectory(
                prefix: "cool-tunnel-core-update")
            // try-ok: defer-block tempdir teardown
            defer { try? FileManager.default.removeItem(at: tempRoot) }
            // **Sw#C4 partial (v0.1.7.18):** download binary AND
            // SHA-256 manifest; refuse to adopt the binary if
            // the hash doesn't match. The redirect guard +
            // trusted-host check constrain where bytes can come
            // from; SHA pinning closes the residual
            // CDN-internal-tamper gap that the redirect guard
            // structurally cannot.
            async let binaryFetch: URL = BinaryUpdaterCore.download(
                url: resolved.downloadURL,
                to: tempRoot.appendingPathComponent("cool-tunnel-core"),
                logger: rustCoreUpdaterLogger,
                userFacingAssetName: "the engine binary"
            )
            // Manifest is ~250 bytes; 1 MB cap matches AppUpdater
            // and refuses an attacker-shaped 100 MB "manifest"
            // before SHAVerifier reads it into memory.
            async let manifestFetch: URL = BinaryUpdaterCore.download(
                url: resolved.manifestURL,
                to: tempRoot.appendingPathComponent(
                    resolved.manifestURL.lastPathComponent),
                maxBytes: 1 * 1024 * 1024,
                logger: rustCoreUpdaterLogger,
                userFacingAssetName: "the engine binary"
            )
            let downloaded = try await binaryFetch
            let manifestPath = try await manifestFetch
            state = .downloading(progress: 1.0)

            try Self.verifyAgainstManifest(
                binary: downloaded,
                manifestURL: manifestPath,
                expectedAssetName: resolved.assetName)

            state = .installing
            // Rust-core lands without the execute bit (lipo'd
            // naive is already 0755 from lipo's output) — chmod
            // before ad-hoc signing.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: downloaded.path)
            try await BinaryUpdaterCore.adhocSign(at: downloaded)
            try BinaryUpdaterCore.atomicallyInstall(
                from: downloaded, to: installedURL)

            // **U#2 fix (v2.0.1):** post-install `--version`
            // verification. SHA-256 verification proves the bytes
            // we wrote are the bytes the publisher signed off
            // on, but says nothing about whether those bytes
            // self-identify as the version the tag claims. v2.0.0
            // shipped a Rust binary that self-reported `0.1.7`
            // because `core/Cargo.toml` was never bumped — the
            // updater happily declared "Updated to v2.0.0" while
            // the verdict pill read `0.1.7`. Refuse to enter
            // `.succeeded` unless the new binary's self-reported
            // semver matches the release tag's semver.
            try await Self.verifyInstalledVersion(
                at: installedURL, matchesTag: resolved.tag)

            tagStore.value = resolved.tag
            state = .succeeded(
                tag: resolved.tag, installedPath: installedURL)
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
        case .checking, .resolvingRelease, .downloading, .installing:
            return true
        default:
            return false
        }
    }

    // MARK: - Rust-core-specific pipeline (off-main)

    /// **Sw#C4 partial (v0.1.7.18):** previously returned just
    /// `(tag, downloadURL)`; pinning required adding the manifest
    /// URL + asset filename, which is the minimal API change.
    private struct ResolvedAsset {
        let tag: String
        let downloadURL: URL
        let manifestURL: URL
        let assetName: String
    }

    /// Newest cool-tunnel release that exposes BOTH a
    /// `cool-tunnel-core-vX.Y.Z(.W)?-universal` asset AND a
    /// matching `Cool-tunnel-vX.Y.Z.sha256` manifest. Walks the
    /// recent-releases list rather than `/releases/latest` so
    /// pre-releases are eligible. A release missing the manifest
    /// is SKIPPED — adopting unverified would defeat the pinning.
    private static func resolveLatestAsset() async throws -> ResolvedAsset {
        guard
            let apiURL = URL(
                string:
                    "https://api.github.com/repos/coo1white/cool-tunnel/releases?per_page=20"
            )
        else {
            throw UpdaterError.message(
                "internal error: invalid hardcoded GitHub API URL")
        }
        let data = try await BinaryUpdaterCore.fetchReleaseJSON(
            apiURL: apiURL, apiKind: "Cool Tunnel")

        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL
            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }
        struct Release: Decodable {
            let tagName: String
            let assets: [Asset]
            enum CodingKeys: String, CodingKey {
                case tagName = "tag_name"
                case assets
            }
        }

        let releases = try JSONDecoder().decode([Release].self, from: data)
        for release in releases {
            guard
                let engineAsset = release.assets.first(where: {
                    $0.name.hasPrefix("cool-tunnel-core-v")
                        && $0.name.hasSuffix("-universal")
                })
            else {
                continue
            }
            let manifestName = "Cool-tunnel-\(release.tagName).sha256"
            guard
                let manifestAsset = release.assets.first(where: {
                    $0.name == manifestName
                })
            else {
                rustCoreUpdaterLogger.info(
                    "skipping \(release.tagName, privacy: .public) — no SHA-256 manifest"
                )
                continue
            }
            guard isTrustedGitHubURL(engineAsset.browserDownloadURL) else {
                throw UpdaterError.message(
                    "GitHub returned an engine asset URL on an unexpected host. Refusing to update."
                )
            }
            guard isTrustedGitHubURL(manifestAsset.browserDownloadURL) else {
                throw UpdaterError.message(
                    "GitHub returned a SHA-256 manifest URL on an unexpected host. Refusing to update."
                )
            }
            return ResolvedAsset(
                tag: release.tagName,
                downloadURL: engineAsset.browserDownloadURL,
                manifestURL: manifestAsset.browserDownloadURL,
                assetName: engineAsset.name
            )
        }
        throw UpdaterError.message(
            "No engine binary with a SHA-256 manifest in the recent Cool Tunnel releases. The bundled engine still works; Update will retry next time."
        )
    }

    /// **Sw#C4 partial (v0.1.7.18):** asserts the downloaded
    /// binary matches the SHA-256 the manifest claims for
    /// `expectedAssetName`. Mirrors `AppUpdater.verifyZipAgainstManifest`
    /// but for a single binary entry rather than a .zip. Don't
    /// echo either hash to the user-facing error (same posture
    /// as AppUpdater Sw-H2): real values go to os_log only.
    nonisolated private static func verifyAgainstManifest(
        binary: URL,
        manifestURL: URL,
        expectedAssetName: String
    ) throws {
        let expected: String?
        do {
            expected = try SHAVerifier.expectedHash(
                for: expectedAssetName, in: manifestURL)
        } catch {
            throw UpdaterError.message(
                "Couldn't read the SHA-256 manifest. Refusing to update."
            )
        }
        guard let expected = expected else {
            rustCoreUpdaterLogger.error(
                "manifest does not include \(expectedAssetName, privacy: .public)"
            )
            throw UpdaterError.message(
                "SHA-256 manifest does not include the engine binary. Refusing to update."
            )
        }
        let actual: String
        do {
            actual = try SHAVerifier.sha256(of: binary)
        } catch {
            throw UpdaterError.message(
                "Couldn't read the downloaded engine binary to verify hash."
            )
        }
        guard actual == expected else {
            rustCoreUpdaterLogger.error(
                "engine binary hash mismatch: expected=\(expected, privacy: .public) actual=\(actual, privacy: .public)"
            )
            throw UpdaterError.message(
                "SHA-256 verification failed for the engine binary. The download may be corrupted or tampered with — refusing to install."
            )
        }
    }

    /// **U#2 fix (v2.0.1):** assert the just-installed binary's
    /// self-reported version (parsed from `--version`) matches
    /// the release tag's stripped semver. Catches the "tag says
    /// v2.0.0 but binary self-reports 0.1.7 because Cargo.toml
    /// wasn't bumped" drift v2.0.0 actually shipped.
    nonisolated private static func verifyInstalledVersion(
        at url: URL,
        matchesTag tag: String
    ) async throws {
        let resolver = RustCoreResolver()
        let descriptor: RustCoreDescriptor
        do {
            descriptor = try await resolver.inspect(
                url: url, origin: .userSupplied)
        } catch {
            rustCoreUpdaterLogger.error(
                "post-install inspect failed: \(error.localizedDescription, privacy: .public)"
            )
            throw UpdaterError.message(
                "Couldn't run --version on the installed engine binary to verify it. Refusing to declare the update successful."
            )
        }
        guard let actualLine = descriptor.version else {
            throw UpdaterError.message(
                "The installed engine binary didn't respond to --version. Refusing to declare the update successful."
            )
        }
        let expectedSemver =
            tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let actualSemver =
            actualLine
            .split(whereSeparator: \.isWhitespace)
            .last
            .map(String.init) ?? ""

        guard !actualSemver.isEmpty, actualSemver == expectedSemver else {
            rustCoreUpdaterLogger.error(
                "version mismatch after install: tag=\(tag, privacy: .public) binary=\(actualLine, privacy: .public)"
            )
            throw UpdaterError.message(
                "Engine binary self-reports “\(actualLine)” but the release tag is “\(tag)”. Refusing to declare the update successful — the upstream Cargo.toml version may not have been bumped for this release."
            )
        }
    }
}
