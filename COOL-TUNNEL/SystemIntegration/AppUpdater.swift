// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//
// In-app self-updater for the Cool Tunnel `.app`. SHA-256
// manifest-pinned: every release ships
// `Cool-tunnel-vX.Y.Z.sha256` alongside the .zip; both are
// downloaded, the hash is cross-checked against the manifest,
// and install is refused on any mismatch.
//
// Pipeline:
//   1. GET /releases/latest; no-op if not newer.
//   2. Download .zip + .sha256 in parallel.
//   3. Stream-hash the .zip and cross-reference the manifest.
//   4. Extract via `ditto -x -k`.
//   5. Walk extraction tree: reject hard links, escaping
//      symlinks, >1 .app, non-directory bundles.
//   6. Verify extracted bundle's `CFBundleIdentifier` matches
//      `canonicalBundleID` (hard-coded, NOT
//      `Bundle.main.bundleIdentifier` which is
//      attacker-controllable), version matches release tag,
//      and `CodeSignVerifier` accepts the bundle.
//   7. Refuse on read-only volume / non-writable folder /
//      locked bundle.
//   8. Refuse on multiple real installs.
//   9. Pre-flight free disk space.
//  10. Write relaunch helper, spawn detached.
//  11. Terminate; helper waits for parent PID, atomic-renames
//      with rollback, then `open`s the new bundle.
//
// No admin escalation: `/Applications` is admin-group writable
// by default. The relaunch helper writes only at the existing
// bundle URL and only after every verification step passes.

import AppKit
import CryptoKit
import Darwin
import Foundation
import Observation
import os

/// Live state of the in-app self-updater. `@Observable` so the
/// Settings panel re-renders as the pipeline progresses.
@MainActor
@Observable
final class AppUpdater {

    /// Pipeline state. Each variant is a UI-renderable phase.
    enum State: Sendable, Equatable {
        case idle
        case checking
        case upToDate(currentVersion: String)
        case available(latest: AvailableRelease)
        case downloading(progress: Double)
        case verifying
        case extracting
        case relaunching
        case failed(message: String)
    }

    /// What the GitHub API said about the newest release.
    struct AvailableRelease: Sendable, Equatable {
        let tag: String  // e.g. "v0.1.7.6"
        let version: String  // e.g. "0.1.7.6"
        let zipURL: URL
        let shaManifestURL: URL
        let releaseNotesURL: URL
        let publishedAt: Date?
    }

    private(set) var state: State = .idle

    init() {}

    // MARK: - Public surface

    /// Steps 1–2: hits GitHub, decides whether an update exists.
    /// Cheap; safe to call from `Settings.onAppear`.
    ///
    /// Version comparison runs BEFORE asset validation: a release
    /// missing its .sha256 should not surface as "missing
    /// manifest" when the user is already on that version.
    func checkForUpdates() async {
        // Only refuse re-entry on a genuinely active later phase.
        // `.checking` is the placeholder the caller already set
        // synchronously via `markEnteringCheck`.
        switch state {
        case .downloading, .verifying, .extracting, .relaunching:
            return
        default:
            break
        }
        state = .checking
        do {
            let metadata = try await Self.fetchLatestReleaseMetadata()
            let current = AppVersion.current.marketingVersion
            if Self.versionIsNewer(metadata.version, than: current) {
                let validated = try Self.validateInstallAssets(metadata)
                state = .available(latest: validated)
            } else {
                state = .upToDate(currentVersion: current)
            }
        } catch UpdaterError.message(let reason) {
            state = .failed(message: reason)
        } catch {
            state = .failed(message: error.localizedDescription)
        }
    }

    /// Steps 3–11: downloads, verifies, extracts, relaunches.
    /// Caller should have moved through `.available` via
    /// `checkForUpdates`.
    func downloadAndInstall(_ release: AvailableRelease) async {
        switch state {
        case .verifying, .extracting, .relaunching:
            return
        default:
            break
        }
        // Detect multiple installed copies BEFORE the helper
        // writes anything: with two installs, LaunchServices may
        // open whichever the helper didn't update, leaving the
        // user with a "successful" update that doesn't take.
        do {
            try await Self.refuseIfMultipleInstalls()
        } catch UpdaterError.message(let reason) {
            state = .failed(message: reason)
            return
        } catch {
            state = .failed(message: error.localizedDescription)
            return
        }
        state = .downloading(progress: 0.0)
        do {
            try await Self.run(release: release) { phase in
                self.state = phase
            }
            // Helper now waits on our PID. Flip state and quit.
            state = .relaunching
            // 1.2 s delay so the `.relaunching` subtitle renders
            // before AppKit starts `applicationShouldTerminate`.
            // Below this Intel Macs miss the transition entirely.
            try? await Task.sleep(nanoseconds: 1_200_000_000)  // try-ok: sleep cancellation
            // Hard-exit watchdog. Clean path is
            // `NSApp.terminate(nil)` → `applicationShouldTerminate`
            // returns `.terminateLater` → orchestrator shutdown
            // calls `reply(toApplicationShouldTerminate: true)`,
            // with a 5 s watchdog as backup. If an in-flight
            // URLSession holds the run loop or a window-close
            // animation races the reply, neither fires and the
            // helper waits on our PID forever. 8 s is past the
            // 5 s clean-shutdown watchdog; any system-proxy
            // state cleanup is recovered by
            // `recoverFromCrashIfNeeded` on the next launch.
            Task.detached {
                try? await Task.sleep(nanoseconds: 8_000_000_000)  // try-ok: sleep cancellation
                Darwin.exit(0)
            }
            await MainActor.run { NSApp.terminate(nil) }
        } catch UpdaterError.message(let reason) {
            state = .failed(message: reason)
        } catch {
            state = .failed(message: error.localizedDescription)
        }
    }

    /// Resets `failed` / `upToDate` / `available` back to idle so
    /// the Settings UI can present a fresh "Check" button.
    func reset() {
        guard !isInFlight else { return }
        state = .idle
    }

    /// `true` when a phase is in flight that further user input
    /// should not interrupt. Used by the Settings UI to
    /// synchronously short-circuit double-clicks before the
    /// async machinery flips `state`.
    var isInFlight: Bool {
        switch state {
        case .checking, .downloading, .verifying, .extracting, .relaunching:
            true
        default:
            false
        }
    }

    /// Synchronously flips `state` to `.checking`. Returns `true`
    /// only when the caller should spawn the follow-up `Task`,
    /// closing the race where two clicks queue concurrent
    /// network requests.
    ///
    /// `@discardableResult` is intentionally absent: the type
    /// system forces the caller to branch on the gate decision,
    /// so a future caller that ignores the return value emits a
    /// "result of call is unused" warning.
    func markEnteringCheck() -> Bool {
        if isInFlight { return false }
        state = .checking
        return true
    }

    /// Same race-defeating role as `markEnteringCheck` for the
    /// download phase. Same no-`@discardableResult` discipline.
    func markEnteringDownload() -> Bool {
        if isInFlight { return false }
        state = .downloading(progress: 0.0)
        return true
    }

    // MARK: - Pipeline (off-main; nonisolated by design)

    /// Bare release metadata. Asset validation is deferred to
    /// `validateInstallAssets` so the "up to date" path can
    /// short-circuit without erroring on a missing manifest.
    private struct ReleaseMetadata: Sendable {
        let tag: String
        let version: String
        let htmlURL: URL
        let publishedAt: Date?
        let assets: [GHAsset]
    }

    private struct GHAsset: Decodable, Sendable {
        let name: String
        let browserDownloadURL: URL
        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    /// Hits GitHub `/releases/latest`. Uses `/latest` (not the
    /// paginated list) so pre-releases are excluded for the
    /// user-facing upgrade flow.
    nonisolated private static func fetchLatestReleaseMetadata() async throws -> ReleaseMetadata {
        guard
            let api = URL(
                string: "https://api.github.com/repos/coo1white/cool-tunnel/releases/latest"
            )
        else {
            throw UpdaterError.message("internal error: invalid GitHub API URL")
        }
        var request = URLRequest(url: api)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Cool-Tunnel-AppUpdater", forHTTPHeaderField: "User-Agent")
        // Asks GitHub's edge to serve fresh — HTTPS bodies are
        // integrity-protected but replayable, so a captured
        // older response could otherwise downgrade the offer.
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.timeoutInterval = 15

        // Shared delegate pins redirects to trusted GitHub hosts.
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(
                for: request, delegate: GitHubRedirectGuard.shared)
        } catch {
            throw UpdaterError.message(
                "Couldn't reach GitHub. Check your internet connection and try again."
            )
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdaterError.message(
                "GitHub returned an unexpected status looking up the latest release."
            )
        }

        struct Release: Decodable {
            let tagName: String
            let htmlURL: URL
            let publishedAt: Date?
            let assets: [GHAsset]
            enum CodingKeys: String, CodingKey {
                case tagName = "tag_name"
                case htmlURL = "html_url"
                case publishedAt = "published_at"
                case assets
            }
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let release: Release
        do {
            release = try decoder.decode(Release.self, from: data)
        } catch {
            throw UpdaterError.message("GitHub release JSON did not parse.")
        }

        // Validate tag shape before it goes near a path or the UI.
        let tag = release.tagName
        guard isValidVersionTag(tag) else {
            throw UpdaterError.message(
                "GitHub returned an unexpected release tag (\(tag)). Refusing to proceed."
            )
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag

        return ReleaseMetadata(
            tag: tag,
            version: version,
            htmlURL: release.htmlURL,
            publishedAt: release.publishedAt,
            assets: release.assets
        )
    }

    /// Confirms the release exposes both .zip and .sha256
    /// assets, and that both URLs point at trusted GitHub hosts.
    nonisolated private static func validateInstallAssets(_ meta: ReleaseMetadata) throws -> AvailableRelease
    {
        let zipName = "Cool-tunnel-\(meta.tag).zip"
        let shaName = "Cool-tunnel-\(meta.tag).sha256"
        guard let zipAsset = meta.assets.first(where: { $0.name == zipName }) else {
            throw UpdaterError.message(
                "Release \(meta.tag) has no \(zipName) asset. The release may not be ready yet."
            )
        }
        guard let shaAsset = meta.assets.first(where: { $0.name == shaName }) else {
            throw UpdaterError.message(
                "Release \(meta.tag) has no \(shaName) integrity manifest. Refusing to update without a hash to verify against."
            )
        }
        // Values outside github.com / *.githubusercontent.com
        // are an attacker-shaped API response or an upstream
        // change we should pause for, not trust silently.
        guard isTrustedGitHubURL(zipAsset.browserDownloadURL) else {
            appUpdaterLogger.info(
                "zip URL not GitHub-hosted: \(zipAsset.browserDownloadURL, privacy: .public)"
            )
            throw UpdaterError.message(
                "GitHub returned a release archive URL on an unexpected host. Refusing to update."
            )
        }
        guard isTrustedGitHubURL(shaAsset.browserDownloadURL) else {
            appUpdaterLogger.info(
                "sha URL not GitHub-hosted: \(shaAsset.browserDownloadURL, privacy: .public)"
            )
            throw UpdaterError.message(
                "GitHub returned a SHA-256 manifest URL on an unexpected host. Refusing to update."
            )
        }
        return AvailableRelease(
            tag: meta.tag,
            version: meta.version,
            zipURL: zipAsset.browserDownloadURL,
            shaManifestURL: shaAsset.browserDownloadURL,
            releaseNotesURL: meta.htmlURL,
            publishedAt: meta.publishedAt
        )
    }

    /// Steps 3–10. Caller maps phases to `state` via `report`.
    nonisolated private static func run(
        release: AvailableRelease,
        report: @escaping @MainActor @Sendable (State) -> Void
    ) async throws {
        let tempRoot = try makeTempDirectory()
        // Any pipeline failure cleans up `tempRoot`; on success
        // the relaunch helper takes ownership and removes it
        // via its own `trap cleanup EXIT`.
        do {
            try await runPipeline(release: release, tempRoot: tempRoot, report: report)
        } catch {
            // try-ok: cleanup of mkdtemp'd dir on pipeline error
            try? FileManager.default.removeItem(at: tempRoot)
            throw error
        }
    }

    nonisolated private static func runPipeline(
        release: AvailableRelease,
        tempRoot: URL,
        report: @escaping @MainActor @Sendable (State) -> Void
    ) async throws {
        // 300 MB ≈ 100 MB .zip + 50 MB extracted bundle + slack
        // for the helper's STAGED copy. Surfaces an actionable
        // "free disk space" error rather than a verbatim ditto
        // stderr containing attacker-influenceable text.
        try requireFreeSpace(at: tempRoot, atLeast: 300 * 1024 * 1024)

        let zipURL = tempRoot.appendingPathComponent(release.zipURL.lastPathComponent)
        let shaURL = tempRoot.appendingPathComponent(release.shaManifestURL.lastPathComponent)

        // Parallel fetches — the manifest fetch typically
        // completes during the .zip's TLS handshake.
        async let zipDownload: Void = download(release.zipURL, to: zipURL)
        async let shaDownload: Void = download(release.shaManifestURL, to: shaURL)
        _ = try await zipDownload
        _ = try await shaDownload
        await MainActor.run { report(.verifying) }

        try verifyZipAgainstManifest(
            zipURL: zipURL,
            manifestURL: shaURL,
            zipFilename: release.zipURL.lastPathComponent
        )

        await MainActor.run { report(.extracting) }
        let extractDir = tempRoot.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(
            at: extractDir, withIntermediateDirectories: true)
        try await unzip(zipURL: zipURL, to: extractDir)

        let extractedAppURL = try locateAppBundle(in: extractDir)
        try await verifyExtractedApp(at: extractedAppURL, expectedVersion: release.version)

        // Returns `needsAdmin` for root-owned bundles
        // (.pkg-installed); throws on read-only volume / locked
        // bundle / wrong-user ownership. Symlink-resolved so a
        // symlinked install path is checked against the real
        // destination, not the alias.
        let runningAppURL = await MainActor.run { Bundle.main.bundleURL.resolvingSymlinksInPath() }
        let needsAdmin = try preflightInstallability(at: runningAppURL)

        // Helper takes ownership of `tempRoot` and removes it
        // after copying. `needsAdmin == true` routes through an
        // osascript chown to bring the bundle under user
        // ownership; subsequent updates take the no-prompt path.
        let parentPID = ProcessInfo.processInfo.processIdentifier
        try spawnRelaunchHelper(
            oldAppURL: runningAppURL,
            newAppURL: extractedAppURL,
            tempRootToClean: tempRoot,
            parentPID: parentPID,
            needsAdminElevation: needsAdmin
        )
    }

    // MARK: - Pipeline helpers

    /// Hard cap on a single asset download. Cool Tunnel zips run
    /// ~12 MB; 100 MB leaves slack while keeping a confused-deputy
    /// URL from filling the user's disk.
    nonisolated private static let maxDownloadBytes: Int64 = 100 * 1024 * 1024

    nonisolated private static func download(_ url: URL, to destination: URL) async throws {
        let request = URLRequest(url: url)
        let (tempURL, response): (URL, URLResponse)
        do {
            (tempURL, response) = try await URLSession.shared.download(
                for: request, delegate: GitHubRedirectGuard.shared)
        } catch {
            throw UpdaterError.message(
                "Download failed for \(url.lastPathComponent). Check your internet connection and try again."
            )
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            // Stage-specific detail goes to os_log; the user
            // message stays generic.
            appUpdaterLogger.info(
                "download non-200 for \(url.lastPathComponent, privacy: .public): \((response as? HTTPURLResponse)?.statusCode ?? -1, privacy: .public)"
            )
            throw UpdaterError.message(
                "GitHub didn't return the update files. Try again later."
            )
        }
        // Size cap. Manifests are ~250 B (cap 1 MB); zips are
        // ~12 MB (cap 100 MB). Fail-closed: any size-read
        // failure (sandbox quirk, missing key) refuses to
        // install — a compromised mirror could otherwise slip
        // past with a multi-GB payload. Real streaming-cancel
        // requires `URLSessionDownloadDelegate`.
        let cap: Int64 =
            url.pathExtension == "sha256"
            ? 1 * 1024 * 1024
            : Self.maxDownloadBytes
        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try FileManager.default.attributesOfItem(atPath: tempURL.path)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)  // try-ok: temp file cleanup before throw
            appUpdaterLogger.info(
                "could not stat downloaded \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            throw UpdaterError.message(
                "Couldn't inspect the downloaded update; refusing to install."
            )
        }
        guard let sizeNumber = attrs[.size] as? NSNumber else {
            try? FileManager.default.removeItem(at: tempURL)  // try-ok: temp file cleanup before throw
            throw UpdaterError.message(
                "Downloaded \(url.lastPathComponent) has no readable size; refusing to install."
            )
        }
        if sizeNumber.int64Value > cap {
            try? FileManager.default.removeItem(at: tempURL)  // try-ok: temp file cleanup before throw
            throw UpdaterError.message(
                "\(url.lastPathComponent) exceeded the \(cap / (1024 * 1024)) MB size limit; refusing to install."
            )
        }
        // `tempRoot` is freshly mkdtemp'd; destination collision
        // is impossible by construction. A future caller passing
        // a pre-existing destination should use
        // `replaceItemAt(_:with:)` (atomic).
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    /// Reads `manifestURL`, finds the line for `zipFilename`,
    /// streams the SHA-256 of `zipURL` and asserts a match.
    /// Any mismatch throws and the caller refuses to install.
    nonisolated private static func verifyZipAgainstManifest(
        zipURL: URL,
        manifestURL: URL,
        zipFilename: String
    ) throws {
        let manifest: String
        do {
            manifest = try String(contentsOf: manifestURL, encoding: .utf8)
        } catch {
            throw UpdaterError.message("Couldn't read the SHA-256 manifest.")
        }
        // Manifest lines: `<sha256>  Cool-tunnel-v0.1.7.6.zip`
        // (two-space separator, BSD/Linux `shasum` default).
        //
        // Split on `\.isNewline`: Swift treats CRLF as a single
        // grapheme cluster, so a manual `$0 == "\n" || $0 == "\r"`
        // splitter never matches it and a Windows-EOL manifest
        // parses as one giant line.
        var expectedSha: String?
        for line in manifest.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let name = String(parts.last ?? "")
            if name == zipFilename {
                expectedSha = String(parts[0]).lowercased()
                break
            }
        }
        guard let expected = expectedSha, expected.count == 64 else {
            throw UpdaterError.message(
                "Manifest does not include a SHA-256 for \(zipFilename). Refusing to update."
            )
        }
        // Validate the entry is 64 hex chars before comparing,
        // so a corrupted line surfaces as "manifest corrupted"
        // rather than "SHA-256 mismatch" — different remediations.
        let isHex = expected.allSatisfy { $0.isHexDigit }
        guard isHex else {
            throw UpdaterError.message(
                "SHA-256 manifest entry for \(zipFilename) is not valid hex. Manifest may be corrupted; refusing to update."
            )
        }
        // Streaming SHA via `FileHandle` 64 KiB at a time. A
        // 12 MB allocation on this path could freeze the
        // Settings UI for ~200 ms on slow disks.
        let actualSha: String
        do {
            actualSha = try SHAVerifier.sha256(of: zipURL)
        } catch {
            throw UpdaterError.message("Couldn't read downloaded archive to verify hash.")
        }
        guard actualSha == expected else {
            // Don't echo either hash into the user-facing
            // string: under MITM the "actual" value is
            // attacker-controlled and showing it normalises
            // attacker output in the UI.
            throw UpdaterError.message(
                "SHA-256 verification failed for \(zipFilename). The download may be corrupted or tampered with — refusing to install."
            )
        }
    }

    /// Uses `/usr/bin/ditto -x -k` to preserve macOS metadata
    /// (`unzip(1)` sometimes drops resource forks / code-sig).
    /// Routed through `Subprocess.run` (concurrent stdout/stderr
    /// drain + timeout) so a verbose-stderr ditto failure can't
    /// deadlock on the kernel pipe buffer (~64 KiB).
    nonisolated private static func unzip(zipURL: URL, to destination: URL) async throws {
        let result: SubprocessResult
        do {
            result = try await Subprocess.run(
                executable: URL(fileURLWithPath: "/usr/bin/ditto"),
                arguments: ["-x", "-k", zipURL.path, destination.path],
                timeout: 120
            )
        } catch {
            throw UpdaterError.message("Couldn't launch ditto to extract update.")
        }
        if result.timedOut {
            throw UpdaterError.message(
                "ditto did not finish extracting within 120s — refusing to continue."
            )
        }
        guard result.success else {
            // ditto stderr can carry absolute paths (revealing
            // home directory layout) plus arbitrary text from
            // hostile archive entry names — log private, show
            // generic.
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            appUpdaterLogger.info(
                "ditto extract failed: \(stderr, privacy: .private)"
            )
            throw UpdaterError.message(
                "Couldn't extract the update archive. Check the diagnostic log for details."
            )
        }
        // `ditto -x -k` preserves archived symlinks, including
        // ones pointing OUTSIDE the extraction dir. Bundle-id +
        // version + codesign verify the .app itself; this walk
        // closes the side-channel.
        try refuseExtractionEscapingSymlinks(in: destination)
    }

    /// Cap on entries the extraction walker inspects. Real
    /// bundles have low-double-digit counts; this bounds
    /// attacker-controlled work multipliers.
    nonisolated private static let maxExtractionSymlinks: Int = 1024

    /// Throws if any entry is a symlink whose realpath escapes
    /// `directory`, or a regular file with `st_nlink > 1`.
    ///
    /// Hard-link rejection: PKZip-ditto preserves hard links, so
    /// a malicious zip can plant `…/Resources/foo` as a hard
    /// link to `~/.ssh/config` or `/etc/passwd`. Post-extraction
    /// the bundle reads attacker-chosen bytes (or, worse, writes
    /// the linked file when updating a resource). `nlinks > 1`
    /// for any file in a freshly-extracted bundle is
    /// unambiguously suspicious.
    nonisolated private static func refuseExtractionEscapingSymlinks(in directory: URL) throws {
        // Canonicalise so the ancestor check is robust against
        // tempdir symlinks (`/var` → `/private/var` on macOS).
        guard let containerComponents = canonicalPathComponents(of: directory.path) else {
            throw UpdaterError.message(
                "Couldn't canonicalise extraction directory; refusing to install."
            )
        }

        guard
            let walker = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey],
                options: []
            )
        else {
            // Couldn't open the directory; the next step (ditto
            // already succeeded) would have noticed the same.
            return
        }
        var symlinksSeen = 0
        for case let item as URL in walker {
            let resources: URLResourceValues
            do {
                resources = try item.resourceValues(forKeys: [
                    .isSymbolicLinkKey, .isRegularFileKey,
                ])
            } catch {
                continue
            }
            let isSymlink = resources.isSymbolicLink ?? false
            // `st_nlink > 1` on a regular file means the inode
            // is shared with another path on disk — possibly
            // outside the extraction. Real bundles have
            // `nlinks == 1` for every regular file.
            if resources.isRegularFile == true && !isSymlink {
                // try-ok: defensive lookup; nil → skip the nlinks check
                let attrs = try? FileManager.default.attributesOfItem(
                    atPath: item.path
                )
                if let nlinks = attrs?[.referenceCount] as? Int,
                    nlinks > 1
                {
                    appUpdaterLogger.info(
                        "hard link rejected: \(item.path, privacy: .public) (nlinks=\(nlinks, privacy: .public))"
                    )
                    throw UpdaterError.message(
                        "Update archive contains a hard link; refusing to install."
                    )
                }
            }
            if !isSymlink { continue }
            // Bail before doing the realpath syscall on a
            // pathologically symlinked archive.
            symlinksSeen += 1
            if symlinksSeen > Self.maxExtractionSymlinks {
                appUpdaterLogger.info(
                    "extraction symlink-count cap exceeded: \(symlinksSeen, privacy: .public) > \(Self.maxExtractionSymlinks, privacy: .public)"
                )
                throw UpdaterError.message(
                    "Update archive contains an unreasonable number of symbolic links; refusing to install."
                )
            }
            // realpath resolves all interior links + `..`
            // segments — the only way to catch a target like
            // `link/../../etc/passwd`. Dangling links are
            // rejected — bundles have no business carrying
            // them.
            guard let targetComponents = canonicalPathComponents(of: item.path) else {
                throw UpdaterError.message(
                    "Update archive contains a broken symbolic link; refusing to install."
                )
            }
            // Component-wise ancestor check. Avoids the
            // trailing-slash false positive (`/extracted-evil`
            // vs `/extracted`) and symlink-traversal-via-target.
            guard targetComponents.starts(with: containerComponents) else {
                throw UpdaterError.message(
                    "Update archive contains a symbolic link pointing outside the extraction directory; refusing to install."
                )
            }
        }
    }

    /// Shared `realpath(3)` wrapper. Returns `nil` on failure so
    /// the call site can carry its own (distinct) error wording.
    nonisolated private static func canonicalPathComponents(of path: String) -> [String]? {
        guard let cStr = realpath(path, nil) else { return nil }
        defer { free(cStr) }
        return URL(fileURLWithPath: String(cString: cStr)).pathComponents
    }

    /// Walks the extraction directory for a single `.app`.
    /// Refuses on zero, multiple, or non-directory bundle.
    nonisolated private static func locateAppBundle(in directory: URL) throws -> URL {
        let items = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        let apps = items.filter { url in
            guard url.pathExtension == "app" else { return false }
            // try-ok: defensive dir check; nil → treat as non-app
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return isDir
        }
        guard apps.count == 1 else {
            throw UpdaterError.message(
                "Update archive contained \(apps.count) .app bundles; expected exactly 1."
            )
        }
        return apps[0]
    }

    /// Sendable carrier for the two strings pulled from
    /// `Info.plist`; `[String: Any]` itself is not Sendable.
    private struct ExtractedAppInfo: Sendable {
        let bundleIdentifier: String
        let shortVersion: String
    }

    /// Verifies the freshly-extracted `.app`:
    /// - bundle ID matches the hard-coded canonical constant
    /// - `CFBundleShortVersionString` matches `expectedVersion`
    /// - `CodeSignVerifier` accepts the bundle
    nonisolated private static func verifyExtractedApp(at appURL: URL, expectedVersion: String) async throws {
        let infoURL =
            appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist", isDirectory: false)
        let info = try await readAppInfo(at: infoURL)

        // Compare to the hard-coded constant, NOT
        // `Bundle.main.bundleIdentifier`: an attacker who
        // substituted the running app would also have written
        // its plist, anchoring trust in attacker-controlled
        // input. The constant baked into the binary is the only
        // safe anchor. ASCII-only check is defence-in-depth
        // against Unicode confusables a future case-insensitive
        // compare or display path would not catch.
        let newBundleID = info.bundleIdentifier.precomposedStringWithCanonicalMapping
        guard newBundleID.allSatisfy(\.isASCII) else {
            throw UpdaterError.message(
                "Bundle identifier contains non-ASCII characters. Refusing to install for safety."
            )
        }
        guard newBundleID == Self.canonicalBundleID else {
            appUpdaterLogger.info(
                "bundle-ID mismatch: got=\(newBundleID, privacy: .public) expected=\(Self.canonicalBundleID, privacy: .public)"
            )
            throw UpdaterError.message(
                "New app's bundle identifier does not match Cool Tunnel. Refusing to install."
            )
        }
        // Don't interpolate `info.shortVersion` (attacker-
        // controlled bytes) into the UI — a Unicode bidi-override
        // or fake-instruction text would otherwise render into
        // the Settings panel.
        guard info.shortVersion == expectedVersion else {
            appUpdaterLogger.info(
                "version mismatch: got=\(info.shortVersion, privacy: .public) expected=\(expectedVersion, privacy: .public)"
            )
            throw UpdaterError.message(
                "New app's version does not match the release tag \(expectedVersion). Refusing to install."
            )
        }

        // Wraps `SecStaticCodeCheckValidity`.
        do {
            try await CodeSignVerifier.verifyValid(at: appURL)
        } catch {
            throw UpdaterError.message(
                "New app failed code-signature verification: \(error.localizedDescription)"
            )
        }
    }

    /// Reads `Info.plist` off the main actor and returns only
    /// the two Sendable strings the caller needs.
    nonisolated private static func readAppInfo(at infoURL: URL) async throws -> ExtractedAppInfo {
        try await Task.detached(priority: .userInitiated) {
            let data: Data
            do {
                data = try Data(contentsOf: infoURL)
            } catch {
                throw UpdaterError.message("Couldn't read new app's Info.plist.")
            }
            let plist: [String: Any]
            do {
                guard
                    let parsed = try PropertyListSerialization.propertyList(
                        from: data, options: [], format: nil) as? [String: Any]
                else {
                    throw UpdaterError.message("New app's Info.plist is malformed.")
                }
                plist = parsed
            } catch UpdaterError.message(let reason) {
                throw UpdaterError.message(reason)
            } catch {
                throw UpdaterError.message("Couldn't parse new app's Info.plist.")
            }
            guard let bundleID = plist["CFBundleIdentifier"] as? String else {
                throw UpdaterError.message(
                    "New app has no bundle identifier. Refusing to install."
                )
            }
            guard let shortVersion = plist["CFBundleShortVersionString"] as? String else {
                throw UpdaterError.message(
                    "New app has no version string. Refusing to install."
                )
            }
            return ExtractedAppInfo(
                bundleIdentifier: bundleID,
                shortVersion: shortVersion
            )
        }.value
    }

    /// Pre-flights the install path. Returns `true` when the
    /// bundle needs admin elevation (`.pkg`-installed,
    /// root-owned). Throws on read-only volume / locked bundle /
    /// wrong-user ownership. The caller routes `true` through
    /// `chownBundleToCurrentUser` so the user enters their
    /// password once; subsequent updates take the no-prompt path.
    nonisolated private static func preflightInstallability(at appURL: URL) throws -> Bool {
        let parentDirectory = appURL.deletingLastPathComponent()
        let parentValues = try parentDirectory.resourceValues(
            forKeys: [.volumeIsReadOnlyKey, .isWritableKey]
        )
        if parentValues.volumeIsReadOnly == true {
            throw UpdaterError.message(
                "Cool Tunnel must be installed in /Applications before it can self-update. Drag the app from the disk image to Applications, then try Update again."
            )
        }
        // Test bundle owner first: a root-owned bundle takes
        // the admin-elevation path, which can write a non-user-
        // writable parent (e.g. /Applications under MDM ACLs).
        // Only check parent-writable for the user-owned arm.
        var st = stat()
        let statOK = appURL.path.withCString { lstat($0, &st) } == 0
        if statOK {
            let lockedFlags = UInt32(UF_IMMUTABLE) | UInt32(SF_IMMUTABLE)
            if (st.st_flags & lockedFlags) != 0 {
                appUpdaterLogger.info(
                    "bundle has chflags uchg/schg: \(appURL.path, privacy: .public)"
                )
                throw UpdaterError.message(
                    "Cool Tunnel's bundle is locked. Right-click the app, choose Get Info, uncheck the Locked checkbox, then try Update again."
                )
            }
            // `.pkg`-installed bundles live under root:wheel.
            // Take the admin-elevation path.
            let myEUID = geteuid()
            if st.st_uid != myEUID && st.st_uid == 0 {
                appUpdaterLogger.info(
                    "bundle is root-owned (.pkg-installed) — taking admin-elevated install path: \(appURL.path, privacy: .public)"
                )
                return true
            }
            // Bundle owned by another non-root user (rare —
            // typically a user-rename / unusual transfer).
            // Refuse and ask the user to check rather than
            // silently chowning to the current user.
            if st.st_uid != myEUID {
                appUpdaterLogger.info(
                    "bundle owned by uid \(st.st_uid, privacy: .public), running as \(myEUID, privacy: .public)"
                )
                throw UpdaterError.message(
                    "Cool Tunnel's bundle is owned by another user (UID \(st.st_uid)). The in-app updater can only modify files owned by the user running the app. Either change the bundle's ownership or reinstall as the current user."
                )
            }
        }
        // User-owned bundle: parent must be writable for the
        // rename pair to succeed. The relaunch helper's `mv` /
        // `ditto` surfaces real errors for any residual case the
        // pre-flight can't classify.
        if parentValues.isWritable == false {
            appUpdaterLogger.info(
                "parent not writable: \(parentDirectory.path, privacy: .public)"
            )
            throw UpdaterError.message(
                "Cool Tunnel can't write to its install location. Check your folder permissions and try Update again."
            )
        }
        return false
    }

    /// Writes the relaunch helper into `tempRootToClean` (NOT
    /// `/tmp`) atomically with mode 0700, then spawns it
    /// detached. The helper waits for the parent PID, dittos
    /// the new app over the old, and `open`s the new copy.
    ///
    /// When `needsAdminElevation` is true an osascript chown
    /// runs first to bring the bundle under user ownership;
    /// the remainder of the helper then takes the standard
    /// (no-prompt) path.
    nonisolated private static func spawnRelaunchHelper(
        oldAppURL: URL,
        newAppURL: URL,
        tempRootToClean: URL,
        parentPID: Int32,
        needsAdminElevation: Bool
    ) throws {
        // Helper script lives inside the per-update tempRoot
        // (restrictive perms; deleted by the script's own EXIT
        // trap). Born with mode 0o700 via
        // `O_CREAT|O_EXCL|O_WRONLY` so there's no post-write/
        // pre-chmod window for a symlink swap.
        let scriptURL =
            tempRootToClean
            .appendingPathComponent("cool-tunnel-relaunch.sh", isDirectory: false)

        // Helper redirects stderr to a stable log path
        // (`~/Library/Logs/cool-tunnel/relaunch.log`) so support
        // can `tail` after a failed update without needing to
        // know which tempRoot was in play.
        let logURL = try Self.makeRelaunchLogPath()

        // Bash relaunch dance:
        //   1. Wait up to 30 s for parent to exit.
        //   2. ditto into a sibling `.new` directory.
        //   3. Atomic-rename pair: old → .old, .new → old.
        //   4. Remove .old.
        //   5. open the new app.
        //
        // The `.new`-stage-then-rename pattern allows rollback
        // on any failure step; a previous `rm -rf` + `ditto`
        // flow would leave the user with no Cool Tunnel
        // installed if ditto failed mid-copy.
        //
        // Capture origUID here in the parent app: by the time
        // the privileged helper runs, `id -u` is `0`.
        let origUID = getuid()

        let script = """
            #!/bin/bash
            set -eu
            PARENT_PID=\(parentPID)
            OLD_APP=\(shellQuote(oldAppURL.path))
            NEW_APP=\(shellQuote(newAppURL.path))
            TEMP_ROOT=\(shellQuote(tempRootToClean.path))
            LOG=\(shellQuote(logURL.path))
            ORIG_UID=\(origUID)
            STAGED="${OLD_APP}.new"
            BACKUP="${OLD_APP}.old-update"

            # Redirect stderr to a user-visible log path so the
            # preswap_trap recovery hint reaches the user (the
            # parent process sets task.standardError = nil before
            # exiting, so without this every `>&2` line is
            # discarded).
            exec 2>>"$LOG"
            echo "[$(date '+%FT%T%z')] cool-tunnel-relaunch starting (parent=$PARENT_PID, uid=$(id -u))"

            # Pre-swap trap: until step 4 commits the swap, an
            # unexpected exit MUST preserve recovery materials so
            # the user can restore manually. After the swap the
            # trap is replaced with destructive cleanup.
            preswap_trap() {
                {
                    echo "[$(date '+%FT%T%z')] update aborted before swap committed."
                    echo "  recovery: $TEMP_ROOT"
                    if [ -d "$BACKUP" ]; then
                        echo "  backup:   $BACKUP"
                    fi
                } >&2
            }
            trap preswap_trap EXIT

            # Wait up to 30 s for parent exit so we can replace
            # the bundle without "file in use" errors.
            for _ in $(seq 1 60); do
                if ! kill -0 "$PARENT_PID" 2>/dev/null; then
                    break
                fi
                sleep 0.5
            done

            # If parent didn't exit, leak rather than corrupt.
            if kill -0 "$PARENT_PID" 2>/dev/null; then
                exit 1
            fi

            # Pre-clean any stale stage/backup.
            rm -rf "$STAGED" "$BACKUP" 2>/dev/null || true

            # 1. Stage via `ditto` (preserves resource forks /
            #    code-signature / xattrs; `cp -R` may not).
            ditto "$NEW_APP" "$STAGED"

            # 2. old → backup. On failure: drop the stage,
            #    leave the original intact, preswap_trap fires.
            if ! mv "$OLD_APP" "$BACKUP" 2>/dev/null; then
                rm -rf "$STAGED"
                exit 1
            fi

            # 3. stage → old. On failure: restore backup BEFORE
            #    removing stage so the user always has an app.
            if ! mv "$STAGED" "$OLD_APP" 2>/dev/null; then
                mv "$BACKUP" "$OLD_APP" 2>/dev/null || true
                rm -rf "$STAGED" 2>/dev/null || true
                exit 1
            fi

            # 4. Drop the backup; swap committed.
            rm -rf "$BACKUP" 2>/dev/null || true

            cleanup() {
                rm -rf "$TEMP_ROOT" 2>/dev/null || true
            }
            trap cleanup EXIT

            # 5. Relaunch. Use `open PATH` (not `open -a NAME`)
            #    so bundle paths with spaces work — `-a` would
            #    treat "Cool" as the app name.
            #
            # On the admin-elevated path: chown the bundle back
            # to the user (so subsequent updates skip the auth
            # prompt) and re-launch via `launchctl asuser` to
            # land in the user's Aqua session (a bare `open`
            # from a root process launches AS root and creates a
            # TCC / keychain mess).
            #
            # `lsregister -f` invalidates the LaunchServices
            # cache entry for the swapped inode so Dock /
            # Finder open the new bundle on next click.
            LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"
            if [ "$(id -u)" -eq 0 ]; then
                chown -R "${ORIG_UID}:staff" "$OLD_APP" 2>/dev/null || true
                if [ -x "$LSREGISTER" ]; then
                    launchctl asuser "${ORIG_UID}" "$LSREGISTER" -f "$OLD_APP" 2>/dev/null || true
                fi
                launchctl asuser "${ORIG_UID}" open "$OLD_APP"
            else
                if [ -x "$LSREGISTER" ]; then
                    "$LSREGISTER" -f "$OLD_APP" 2>/dev/null || true
                fi
                open "$OLD_APP"
            fi
            """

        // `RestrictedFile.write`'s `O_CREAT|O_EXCL`-then-fsync-
        // then-rename creates the file with mode 0o700 at birth,
        // so there's no post-write/pre-chmod race.
        guard let scriptData = script.data(using: .utf8) else {
            throw UpdaterError.message(
                "Internal error: relaunch script not encodable as UTF-8."
            )
        }
        do {
            try RestrictedFile.write(scriptData, to: scriptURL, mode: 0o700)
        } catch {
            throw UpdaterError.message(
                "Couldn't create the relaunch helper script: \(error.localizedDescription)"
            )
        }

        // On macOS 15+ / 26 (Tahoe) the privileged-shell
        // sandbox kills children of the authorization-elevated
        // shell on exit regardless of `nohup`/`disown`, so a
        // `osascript`-spawned helper never actually runs. Use
        // osascript ONLY for the chown (fast, atomic, doesn't
        // background); the bundle is then user-owned and the
        // regular spawn below takes over.
        if needsAdminElevation {
            try chownBundleToCurrentUser(at: oldAppURL)
        }

        // Spawn detached; the parent is about to NSApp.terminate.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [scriptURL.path]
        task.standardInput = nil
        task.standardOutput = nil
        task.standardError = nil
        do {
            try task.run()
        } catch {
            throw UpdaterError.message(
                "Couldn't launch the relaunch helper: \(error.localizedDescription)"
            )
        }
    }

    /// Asks for admin privileges via the standard macOS auth
    /// dialog and `chown -R`s the bundle at `oldAppURL` to the
    /// current user. Surfaces user-cancel and auth-failure as
    /// clear `UpdaterError.message`s.
    nonisolated private static func chownBundleToCurrentUser(at oldAppURL: URL) throws {
        let myUID = Int(geteuid())
        let appleScript =
            "do shell script \"/usr/sbin/chown -R \(myUID):staff \" "
            + "& quoted form of \(appleScriptStringLiteral(oldAppURL.path)) "
            + "with prompt \"Cool Tunnel needs to take ownership of its application bundle. "
            + "(It was originally installed via the .pkg installer, so the bundle is owned by root. "
            + "After this one-time step, future updates won't ask for your password.)\" "
            + "with administrator privileges"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", appleScript]
        task.standardInput = nil
        task.standardOutput = Pipe()
        let stderrPipe = Pipe()
        task.standardError = stderrPipe
        do {
            try task.run()
        } catch {
            throw UpdaterError.message(
                "Couldn't launch the admin-privileges prompt: \(error.localizedDescription)"
            )
        }
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8) ?? ""
            appUpdaterLogger.warning(
                "chown osascript failed (status \(task.terminationStatus, privacy: .public)): \(errText, privacy: .public)"
            )
            // osascript exits status 1 with stderr "User
            // canceled. (-128)" on dialog dismissal — surface a
            // friendly message for that specific case.
            if errText.contains("-128") || errText.contains("User canceled")
                || errText.contains("User cancelled")
            {
                throw UpdaterError.message(
                    "Update cancelled — admin password not entered. Click Update to try again."
                )
            }
            throw UpdaterError.message(
                "Couldn't take ownership of Cool Tunnel's bundle. "
                    + "Try again, or reinstall from the .dmg."
            )
        }
        // Verify the chown took effect: osascript can report
        // success while the chown silently fails, which would
        // leave the bundle root-owned and the subsequent
        // user-owned spawn path failing at the `mv`.
        var st = stat()
        if oldAppURL.path.withCString({ lstat($0, &st) }) == 0,
            st.st_uid != geteuid()
        {
            appUpdaterLogger.warning(
                "chown osascript reported success but bundle is still owned by uid \(st.st_uid, privacy: .public)"
            )
            throw UpdaterError.message(
                "Bundle ownership change didn't take effect; please reinstall from the .dmg."
            )
        }
    }

    /// Encodes a string as an AppleScript literal so file paths
    /// can be safely interpolated into `do shell script`.
    nonisolated private static func appleScriptStringLiteral(_ value: String) -> String {
        let escaped =
            value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Uses Spotlight (`mdfind`) to find every `.app` matching
    /// the canonical bundle ID and refuses if more than one
    /// real install exists. Xcode build artifacts are filtered
    /// out via [`isPlausibleUserInstall`].
    nonisolated private static func refuseIfMultipleInstalls() async throws {
        let result: SubprocessResult
        do {
            result = try await Subprocess.run(
                executable: URL(fileURLWithPath: "/usr/bin/mdfind"),
                arguments: [
                    "kMDItemCFBundleIdentifier == \"\(canonicalBundleID)\""
                ],
                timeout: 10
            )
        } catch {
            // Not fatal — Spotlight may be disabled / indexing.
            appUpdaterLogger.warning(
                "mdfind launch failed: \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        if result.timedOut || !result.success {
            appUpdaterLogger.warning(
                "mdfind did not return cleanly; skipping multi-install check"
            )
            return
        }
        // Filter Xcode build artifacts before counting —
        // Spotlight indexes DerivedData by default.
        let paths = result.stdout
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }
            .filter { Self.isPlausibleUserInstall($0) }
        if paths.count > 1 {
            appUpdaterLogger.error(
                "multiple real installs detected: \(paths.joined(separator: ", "), privacy: .public)"
            )
            // List actual paths so the user knows where to look
            // rather than hunting in Finder by hand.
            let pathList =
                paths
                .map { "  • \($0)" }
                .joined(separator: "\n")
            throw UpdaterError.message(
                """
                Multiple copies of Cool Tunnel were found on this Mac:
                \(pathList)
                Move all but one to the Trash, restart the app you want to keep, and try Update again.
                """
            )
        }
    }

    /// Filters Spotlight hits to plausible user installs only,
    /// excluding Xcode build artifacts. False positives here
    /// block every update for every developer; missed real
    /// installs only re-fire this check next click — so
    /// under-trim.
    nonisolated fileprivate static func isPlausibleUserInstall(_ path: String) -> Bool {
        let xcodeBuildMarkers = [
            "/DerivedData/",
            "/Build/Products/",
            "/Library/Developer/Xcode/",
        ]
        for marker in xcodeBuildMarkers where path.contains(marker) {
            return false
        }
        // Match `*/build/DerivedData/*` and `*/build/Build/Products/*`
        // explicitly so a legitimate `/Applications/build-tools/X.app`
        // still passes.
        if path.contains("/build/DerivedData/")
            || path.contains("/build/Build/Products/")
        {
            return false
        }
        return true
    }

    /// Asserts that the volume has at least `bytes` available
    /// for "important usage" — the resource key macOS exposes
    /// for pre-flight checks.
    nonisolated private static func requireFreeSpace(at url: URL, atLeast bytes: Int64) throws {
        let values = try url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey
        ])
        if let available = values.volumeAvailableCapacityForImportantUsage,
            available < bytes
        {
            let availableMB = available / (1024 * 1024)
            let requiredMB = bytes / (1024 * 1024)
            appUpdaterLogger.error(
                "free-space pre-flight failed: available=\(availableMB, privacy: .public)MB required=\(requiredMB, privacy: .public)MB"
            )
            throw UpdaterError.message(
                "Not enough disk space to install the update (\(availableMB) MB free, \(requiredMB) MB needed). Free a few hundred megabytes and try again."
            )
        }
    }

    nonisolated private static func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cool-tunnel-app-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Returns `~/Library/Logs/cool-tunnel/relaunch.log` and
    /// ensures the parent directory exists. The bash helper
    /// appends (not truncates) so successive failures leave a
    /// chronological audit trail.
    nonisolated private static func makeRelaunchLogPath() throws -> URL {
        guard
            let library = FileManager.default
                .urls(for: .libraryDirectory, in: .userDomainMask)
                .first
        else {
            throw UpdaterError.message(
                "Couldn't locate user Library directory."
            )
        }
        let dir =
            library
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("cool-tunnel", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let logURL = dir.appendingPathComponent("relaunch.log", isDirectory: false)
        // Defend against a pre-planted symlink: an attacker with
        // prior file-write access in the user's home could
        // pre-create `relaunch.log` as a symlink to an
        // unwritable path; bash's `exec 2>>"$LOG"` would
        // silently fail and the diagnostic hint vanish. If the
        // path exists and isn't a regular file, unlink it.
        // try-ok: defensive lookup; nil → leave the file alone
        let resources = try? logURL.resourceValues(forKeys: [
            .isSymbolicLinkKey, .isRegularFileKey,
        ])
        if let r = resources,
            r.isSymbolicLink == true || r.isRegularFile != true
        {
            appUpdaterLogger.info(
                "removing non-regular relaunch.log at \(logURL.path, privacy: .public)"
            )
            // try-ok: best-effort unlink of non-regular relaunch log
            try? FileManager.default.removeItem(at: logURL)
        }
        return logURL
    }

    // MARK: - Version + tag parsing

    /// Validates a tag matches `v?N.N.N(.N)?`.
    nonisolated static func isValidVersionTag(_ tag: String) -> Bool {
        guard !tag.isEmpty, tag.count <= 64 else { return false }
        let pattern = #"^v?\d+(\.\d+){1,3}(-[A-Za-z0-9.]+)?$"#
        return tag.range(of: pattern, options: .regularExpression) != nil
    }

    /// Returns `true` if `candidate` strictly outranks `base`
    /// under segment-wise numeric compare. Both must be canonical
    /// (no leading `v`).
    ///
    /// Pre-release markers (`-`) and non-numeric segments
    /// short-circuit to `false` (no upgrade offered): a permissive
    /// `Int($0) ?? 0` would coerce `0-rc1` to 0 and compare
    /// `1.0.0-rc1` equal to `1.0.0`.
    nonisolated static func versionIsNewer(_ candidate: String, than base: String) -> Bool {
        guard let lhs = parseVersionSegments(candidate),
            let rhs = parseVersionSegments(base)
        else {
            return false
        }
        let len = max(lhs.count, rhs.count)
        for i in 0..<len {
            let l = i < lhs.count ? lhs[i] : 0
            let r = i < rhs.count ? rhs[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// Parses `"N.N.N"` or `"N.N.N.N"` into integer segments.
    /// Returns `nil` on any `-` (pre-release marker) or any
    /// non-strict-numeric segment.
    nonisolated private static func parseVersionSegments(_ version: String) -> [Int]? {
        if version.contains("-") { return nil }
        var segments: [Int] = []
        for raw in version.split(separator: ".") {
            guard let value = Int(raw), value >= 0 else { return nil }
            segments.append(value)
        }
        return segments.isEmpty ? nil : segments
    }

    /// Quotes for bash single-quoted context (`'\''` escape).
    nonisolated private static func shellQuote(_ arg: String) -> String {
        "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Identity constants

    /// Canonical Cool Tunnel bundle identifier — hard-coded so
    /// `verifyExtractedApp` has an attacker-independent anchor.
    /// `Bundle.main.bundleIdentifier` reads the running process's
    /// plist, which an attacker who substituted the running app
    /// could rewrite. Must match `PRODUCT_BUNDLE_IDENTIFIER` in
    /// `project.pbxproj`; update both in lock-step.
    ///
    /// **v3.0.0:** the `.naive` segment is preserved verbatim —
    /// this string is the persistence anchor for every existing
    /// installation. Renaming it would orphan v2.x users'
    /// auto-update path (the mdfind/canonical-bundle-id check
    /// would see the new build as "not a Cool Tunnel install" and
    /// refuse to update). See KeychainStore's same-named comment
    /// for the parallel persistence-tied identifier rationale.
    nonisolated fileprivate static let canonicalBundleID = "space.coolwhite.naive"
}

// MARK: - Logging

/// Captures stage-specific detail (failing URLs, version-mismatch
/// values, status codes) deliberately stripped from user-facing
/// errors. Recoverable via
/// `log show --predicate 'subsystem == "space.coolwhite.cooltunnel"
/// AND category == "AppUpdater"'`.
private let appUpdaterLogger = Logger.cooltunnel("AppUpdater")
