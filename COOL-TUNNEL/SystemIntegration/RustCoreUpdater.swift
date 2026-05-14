// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
// SystemIntegration/RustCoreUpdater.swift
//
// Downloads the latest `cool-tunnel-core` Mach-O from the
// official Cool Tunnel GitHub release (coo1white/cool-tunnel),
// ad-hoc signs it, and atomically installs into the user's
// Application Support directory so the Settings → Rust Core →
// Update flow can refresh the engine without reinstalling the
// whole .app.
//
// Why a separate updater (vs reusing NaiveUpdater): the naive
// updater downloads upstream NaiveProxy tarballs and lipo-merges
// arm64 + x86_64 itself. The Rust core updater downloads our own
// pre-merged universal binary, which `scripts/package_release.sh`
// publishes as a standalone release asset alongside the .dmg /
// .pkg / .zip.
//
// Wire flow:
//   1. GET https://api.github.com/repos/coo1white/cool-tunnel/releases
//      → pick the newest release (pre-release allowed because
//        every cool-tunnel-core build matches a cool-tunnel
//        release, including pre-releases).
//   2. Locate the asset whose name matches
//      `cool-tunnel-core-vX.Y.Z(.W)?-universal`.
//   3. Download it to a temp file.
//   4. Ad-hoc sign with `/usr/bin/codesign --force --sign -`.
//   5. Atomically install at
//      `~/Library/Application Support/COOL-TUNNEL/cool-tunnel-core-managed`
//      with mode 0755.
//
// The new binary takes effect on the next app launch. The
// orchestrator only spawns the engine once (in
// `bootstrapIfNeeded`), and hot-swapping a long-lived
// JSON-over-stdio subprocess mid-session would invalidate every
// in-flight request — out of scope for this release.

import Foundation
import Observation
import os

/// Module-level logger. **Cross-F#2 (v0.1.7.16):** added so
/// security-relevant rejects (untrusted host, oversize, network
/// failure) leave a trace support can find via
/// `log show --predicate 'subsystem == "space.coolwhite.cooltunnel"
/// AND category == "RustCoreUpdater"'`.
private let rustCoreUpdaterLogger = Logger.cooltunnel("RustCoreUpdater")

/// Live state of an in-flight or finished Rust core update.
/// `@Observable` so the Settings view re-renders as the updater
/// advances through the pipeline without manual binding plumbing.
@MainActor
@Observable
final class RustCoreUpdater {

    /// What the updater is doing right now.
    /// **v2.0.2:** `checking` / `upToDate` / `available` mirror
    /// AppUpdater + NaiveUpdater. Pre-2.0.2 the only entry point
    /// was `update()` which always re-downloaded — clicking
    /// "Update again" on an already-current engine pulled the
    /// same bytes again. The check phase surfaces "you're on the
    /// latest version (X)" when the installed binary's
    /// `--version` matches the release tag's stripped semver.
    enum State: Sendable, Equatable {
        case idle
        case checking
        case upToDate(currentVersion: String, latestTag: String)
        case available(tag: String, currentVersion: String)
        case resolvingRelease
        case downloading(progress: Double)
        case installing
        /// Finished successfully. `tag` is the Cool Tunnel release
        /// tag the binary came from; `installedPath` is the path
        /// the orchestrator should pick up on the next launch.
        case succeeded(tag: String, installedPath: URL)
        case failed(message: String)
    }

    private(set) var state: State = .idle
    /// Most recently installed Cool Tunnel release tag for the
    /// engine binary. Persisted so a relaunch doesn't reset the
    /// comparison baseline (the engine version is shared with the
    /// app marketing version, so this is mostly a belt-and-braces
    /// match against `lastInstalledTag == latestTag`).
    private(set) var lastInstalledTag: String? {
        didSet {
            UserDefaults.standard.set(
                lastInstalledTag, forKey: Self.lastInstalledTagKey)
        }
    }

    private static let lastInstalledTagKey = "RustCoreUpdater.lastInstalledTag"

    private let supportDirectory: URL

    init(supportDirectory: URL) {
        self.supportDirectory = supportDirectory
        self.lastInstalledTag = UserDefaults.standard.string(
            forKey: Self.lastInstalledTagKey)
    }

    convenience init(paths: AppSupportPaths) {
        self.init(supportDirectory: paths.supportDirectory)
    }

    /// Stable target path. Used by Settings as the value to write
    /// into `customRustCorePath` after a successful update.
    var installedURL: URL {
        supportDirectory.appendingPathComponent(
            "cool-tunnel-core-managed",
            isDirectory: false
        )
    }

    /// **v2.0.2:** queries `/releases` for the newest engine
    /// asset and compares against the running binary's
    /// `--version`. Leaves the updater in `.upToDate` (no action
    /// needed) or `.available` (Update button now meaningful).
    /// Re-running while a previous check OR update is in flight
    /// is a no-op so the state machine stays monotonic.
    func checkForUpdates(currentVersion: String) async {
        switch state {
        case .checking, .resolvingRelease, .downloading, .installing:
            return
        default:
            break
        }
        // **v2.0.24 hotfix:** if the managed binary at `installedURL`
        // is gone (deleted by user, lost in Application Support
        // cleanup, never installed on this Mac, etc.), a persisted
        // `lastInstalledTag` from UserDefaults is stale and points at
        // nothing. Without this self-heal `tagIsConsideredCurrent`
        // returns true on the stale tag and the panel says "You're on
        // the latest version ()." (empty parens because
        // `currentVersion` is empty pre-Test) while the engine is in
        // fact missing — the contradictory NG/OK seen in 2.0.23.
        if !FileManager.default.fileExists(atPath: installedURL.path) {
            lastInstalledTag = nil
        }
        state = .checking
        do {
            let resolved = try await Self.resolveLatestAsset()
            if Self.tagIsConsideredCurrent(
                resolved.tag,
                forBinaryVersion: currentVersion,
                lastInstalled: lastInstalledTag
            ) {
                state = .upToDate(
                    currentVersion: currentVersion,
                    latestTag: resolved.tag
                )
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

    /// See `NaiveUpdater.tagIsConsideredCurrent` for rationale.
    /// Same shape: exact tag match against the persisted
    /// `lastInstalledTag` OR semver match against the binary's
    /// `--version` line (after stripping `v` prefix and `-N`
    /// suffix from the tag).
    nonisolated static func tagIsConsideredCurrent(
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
        // binaryVersion is like "cool-tunnel-core 2.0.1" — last
        // whitespace token is the bare semver.
        let binarySemver =
            binaryVersion
            .split(whereSeparator: \.isWhitespace).last
            .map(String.init) ?? binaryVersion
        return !tagSemver.isEmpty && tagSemver == binarySemver
    }

    /// Kicks off the update. Re-entry while a previous run is
    /// in flight is a no-op so the state machine stays monotonic.
    @discardableResult
    func update() async -> URL? {
        switch state {
        case .checking, .resolvingRelease, .downloading, .installing:
            return nil
        default:
            break
        }

        // **v2.0.2 note:** in the Check → Update flow we re-
        // fetch `/releases` here even though `checkForUpdates`
        // just did. The full `ResolvedAsset` (download URL +
        // manifest URL + asset filename) isn't part of the
        // observable State, so the only cheap way to keep
        // structural correctness is a fresh resolve. One extra
        // metadata GET; not the redundant binary download the
        // user-visible bug was about.
        do {
            state = .resolvingRelease
            let resolved = try await Self.resolveLatestAsset()

            state = .downloading(progress: 0.0)
            let tempRoot = try Self.makeTempDirectory()
            // try-ok: defer-block tempdir teardown
            defer { try? FileManager.default.removeItem(at: tempRoot) }
            // **Sw#C4 partial (v0.1.7.18):** download both the
            // engine binary AND the SHA-256 manifest. Refuse to
            // adopt the binary if the hash doesn't match the
            // manifest line for this exact asset filename. The
            // manifest URL comes from the same release JSON
            // (host-validated) and the redirect guard already
            // constrains where the bytes can come from — but
            // SHA pinning is what closes the residual
            // CDN-internal-tamper gap that the redirect guard
            // structurally cannot.
            async let binaryFetch: URL = Self.download(
                url: resolved.downloadURL,
                to: tempRoot.appendingPathComponent("cool-tunnel-core")
            )
            // Manifest is ~250 bytes; 1 MB cap matches AppUpdater
            // and refuses an attacker-shaped 100 MB "manifest"
            // before SHAVerifier reads it into memory.
            async let manifestFetch: URL = Self.download(
                url: resolved.manifestURL,
                to: tempRoot.appendingPathComponent(
                    resolved.manifestURL.lastPathComponent),
                maxBytes: 1 * 1024 * 1024
            )
            let downloaded = try await binaryFetch
            let manifestPath = try await manifestFetch
            state = .downloading(progress: 1.0)

            try Self.verifyAgainstManifest(
                binary: downloaded,
                manifestURL: manifestPath,
                expectedAssetName: resolved.assetName
            )

            state = .installing
            // **CONC-F#1 (v0.1.7.15):** `adhocSign` now async.
            try await Self.adhocSign(at: downloaded)
            try Self.atomicallyInstall(from: downloaded, to: installedURL)

            // **U#2 fix (v2.0.1):** post-install `--version`
            // verification. Pre-2.0.1 we declared
            // `state = .succeeded(tag: resolved.tag, …)` based
            // solely on the SHA-256 match — which is fine for
            // proving the bytes we downloaded are the bytes the
            // release publisher signed off on, but says nothing
            // about whether those bytes actually self-identify
            // as the version the tag claims. v2.0.0 shipped a
            // Rust binary that self-reported `0.1.7` because the
            // `core/Cargo.toml` version field was never bumped;
            // the updater happily declared "Updated to v2.0.0"
            // while the verdict pill read `cool-tunnel-core 0.1.7`.
            // Now: run the new binary's `--version` and refuse
            // to enter `.succeeded` unless its self-reported
            // semver matches the release tag's semver.
            try await Self.verifyInstalledVersion(
                at: installedURL, matchesTag: resolved.tag)

            lastInstalledTag = resolved.tag
            state = .succeeded(tag: resolved.tag, installedPath: installedURL)
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
        switch state {
        case .checking, .resolvingRelease, .downloading, .installing:
            return
        default:
            state = .idle
        }
    }

    // MARK: - Pipeline (off-main)

    /// Aggregate of the resolved release: tag, the
    /// `cool-tunnel-core-vX.Y.Z(.W)?-universal` download URL,
    /// the matching SHA-256 manifest URL
    /// (`Cool-tunnel-vX.Y.Z.sha256`), and the asset filename
    /// the manifest is keyed on.
    ///
    /// **Sw#C4 partial (v0.1.7.18):** previously this returned
    /// just `(tag, downloadURL)` — pinning required adding the
    /// manifest URL to the resolved tuple, which is the
    /// minimal API surface change.
    private struct ResolvedAsset {
        let tag: String
        let downloadURL: URL
        let manifestURL: URL
        let assetName: String
    }

    /// Returns the newest cool-tunnel release that exposes both
    /// a `cool-tunnel-core-vX.Y.Z(.W)?-universal` asset AND a
    /// matching `Cool-tunnel-vX.Y.Z.sha256` manifest. Walks the
    /// recent-releases list rather than hitting
    /// `/releases/latest` because pre-releases may be the only
    /// builds for a while. A release missing the manifest is
    /// SKIPPED (not adopted unverified) — this is the SHA-pin
    /// posture.
    private static func resolveLatestAsset() async throws -> ResolvedAsset {
        // Compile-time constant URL — same audit-driven safe-unwrap
        // pattern as `NaiveUpdater.resolveLatestStableTag`.
        guard
            let apiURL = URL(
                string: "https://api.github.com/repos/coo1white/cool-tunnel/releases?per_page=20")
        else {
            throw UpdaterError.message("internal error: invalid hardcoded GitHub API URL")
        }
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Cool-Tunnel-Updater", forHTTPHeaderField: "User-Agent")
        // **SEC-F#11 (v0.1.7.15):** discourage edge caching /
        // 0-RTT replay of the metadata response.
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        // **R-F#4 (v0.1.7.13):** redirect guard from
        // `GitHubTrust.swift`. Same threat model as
        // `NaiveUpdater`: no SHA pinning today (deferred to
        // v0.2.0 per AppUpdater Sw#C4), so the redirect guard is
        // the only barrier against a compromised CDN or upstream
        // redirect serving a substituted engine binary.
        let (data, response) = try await URLSession.shared.data(
            for: request, delegate: GitHubRedirectGuard.shared
        )
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdaterError.message(
                "Couldn't reach GitHub to look up the latest Cool Tunnel release. Check your internet connection and try again."
            )
        }

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
            // Engine asset
            guard
                let engineAsset = release.assets.first(where: {
                    $0.name.hasPrefix("cool-tunnel-core-v") && $0.name.hasSuffix("-universal")
                })
            else {
                continue
            }
            // **Sw#C4 partial (v0.1.7.18):** require the
            // SHA-256 manifest to be present in the same release.
            // A release without it is SKIPPED — adopting the
            // binary unverified would defeat the purpose of
            // adding pinning. Older releases that predate the
            // manifest publishing era will be silently skipped;
            // the in-app updater will retry next time the user
            // clicks Update.
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
            // **R-F#4:** trusted-host check on both URLs.
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
    /// engine binary matches the SHA-256 the manifest claims
    /// for `expectedAssetName`. Throws on any mismatch — caller
    /// treats that as a refusal to install. Mirrors
    /// `AppUpdater.verifyZipAgainstManifest` but for a single
    /// binary entry rather than a .zip.
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
            // Don't echo either hash to the user-facing error
            // (same posture as AppUpdater Sw-H2): a MITM's
            // hash would otherwise appear in the UI. Real
            // values go to os_log only.
            rustCoreUpdaterLogger.error(
                "engine binary hash mismatch: expected=\(expected, privacy: .public) actual=\(actual, privacy: .public)"
            )
            throw UpdaterError.message(
                "SHA-256 verification failed for the engine binary. The download may be corrupted or tampered with — refusing to install."
            )
        }
    }

    /// Delegates to `GitHubRedirectGuard.download` — the shared
    /// host-validated, redirect-guarded, size-capped download
    /// primitive. Engine binary is ~5 MB so the default 100 MB
    /// cap is generous slack; callers that download a small
    /// sidecar (e.g. the .sha256 manifest at ~250 bytes) pass
    /// a tighter `maxBytes` to refuse a confused-deputy /
    /// attacker-shaped oversized response before
    /// `SHAVerifier.expectedHash` reads it into memory.
    private static func download(
        url: URL,
        to destination: URL,
        maxBytes: Int64 = 100 * 1024 * 1024
    ) async throws -> URL {
        do {
            return try await GitHubRedirectGuard.download(
                url: url, to: destination, maxBytes: maxBytes)
        } catch let untrusted as UntrustedGitHubHostError {
            // **OPSEC (post-v2.0.50):** host-only, never the
            // full URL — same discipline as the SubscriptionClient
            // and GitHubTrust redirect handlers.
            let host = untrusted.url.host ?? "<unknown>"
            rustCoreUpdaterLogger.error(
                "untrusted host: \(host, privacy: .public)"
            )
            throw UpdaterError.message(
                "Refusing to download from non-GitHub host."
            )
        } catch let oversize as OversizeDownloadError {
            rustCoreUpdaterLogger.error(
                "oversize download: actual=\(oversize.actual, privacy: .public) cap=\(oversize.cap, privacy: .public)"
            )
            throw UpdaterError.message(
                "Download exceeded the size limit; refusing to install."
            )
        } catch {
            rustCoreUpdaterLogger.warning(
                "download failure: \(error.localizedDescription, privacy: .public)"
            )
            throw UpdaterError.message(
                "Couldn't download the engine binary. Check your internet connection and try Update again."
            )
        }
    }

    nonisolated private static func adhocSign(at url: URL) async throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
        try await runProcess(
            executable: "/usr/bin/codesign",
            arguments: ["--force", "--sign", "-", "--timestamp=none", url.path]
        )
    }

    private static func atomicallyInstall(from source: URL, to destination: URL) throws {
        let staged = destination.appendingPathExtension("new")
        if FileManager.default.fileExists(atPath: staged.path) {
            try FileManager.default.removeItem(at: staged)
        }
        try FileManager.default.copyItem(at: source, to: staged)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: staged.path
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: destination)
        }
    }

    private static func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cool-tunnel-core-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Async subprocess helper. **CONC-F#1 (v0.1.7.15):**
    /// previously sync + `process.waitUntilExit()`, blocking
    /// MainActor through the codesign duration. Now routes
    /// through `Subprocess.run` matching `NaiveUpdater.runProcess`
    /// and `AppUpdater.unzip`.
    nonisolated private static func runProcess(
        executable: String, arguments: [String]
    ) async throws {
        let result: SubprocessResult
        do {
            result = try await Subprocess.run(
                executable: URL(fileURLWithPath: executable),
                arguments: arguments,
                timeout: 120
            )
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
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdaterError.message(
                "\(URL(fileURLWithPath: executable).lastPathComponent) exit \(result.exitCode): \(stderr)"
            )
        }
    }
}

// **ARCH-F#1 (v0.1.7.15):** the file-scope `RustUpdaterError`
// moved to `SystemIntegration/UpdaterError.swift` and is now
// shared across all three updaters under one name.

extension RustCoreUpdater {
    /// **U#2 fix (v2.0.1):** asserts the just-installed engine
    /// binary's self-reported version (parsed from `--version`)
    /// matches the release tag we downloaded from. Throws
    /// `UpdaterError.message` on any mismatch — caller treats
    /// that as a refusal to declare the update successful.
    ///
    /// Why this exists: SHA-256 verification proves the bytes
    /// we wrote to disk are the bytes the release publisher
    /// signed off on, but it doesn't prove those bytes were
    /// built from a `Cargo.toml` whose `version` field matches
    /// the release tag. v2.0.0 shipped exactly this drift —
    /// the binary self-reported `0.1.7` while the tag was
    /// `v2.0.0`. From v2.0.1 forward, the updater catches the
    /// drift at install time rather than letting it surface
    /// later as a confusing "verdict pill says 0.1.7 but
    /// updater says 2.0.0" UI state.
    nonisolated fileprivate static func verifyInstalledVersion(
        at url: URL,
        matchesTag tag: String
    ) async throws {
        let resolver = RustCoreResolver()
        let descriptor: RustCoreDescriptor
        do {
            descriptor = try await resolver.inspect(url: url, origin: .userSupplied)
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
        // descriptor.version is like "cool-tunnel-core 2.0.1";
        // tag is like "v2.0.1". Extract the bare semver from
        // both and compare.
        let expectedSemver = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
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
