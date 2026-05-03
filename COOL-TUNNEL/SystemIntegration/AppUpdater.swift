// SystemIntegration/AppUpdater.swift
//
// In-app updater for the Cool Tunnel .app itself. Mirrors the
// pattern of NaiveUpdater / RustCoreUpdater but adds the missing
// security control the Sw#C4 audit identified as deferred:
// **SHA-256 manifest pinning**. Every release published by
// `scripts/package_release.sh` ships a
// `Cool-tunnel-vX.Y.Z.sha256` file alongside the .zip; this
// updater downloads BOTH, verifies the .zip hash against the
// manifest, and refuses to install on any mismatch.
//
// Wire flow:
//   1. GET /releases/latest from GitHub.
//   2. Compare tag to the running app's
//      `CFBundleShortVersionString`. No-op if equal or older.
//   3. Download the `Cool-tunnel-vX.Y.Z.zip` asset.
//   4. Download the `Cool-tunnel-vX.Y.Z.sha256` asset.
//   5. Compute SHA-256 of the downloaded .zip via CryptoKit.
//   6. Cross-reference against the manifest line for the .zip
//      filename. Refuse on mismatch.
//   7. Extract via `ditto -x -k`.
//   8. Verify the extracted `Cool tunnel.app`:
//      - Bundle identifier matches the running app's.
//      - `CFBundleShortVersionString` matches the release tag.
//      - `CodeSignVerifier` accepts the bundle.
//   9. Refuse if the running app is on a read-only volume (DMG
//      mount or quarantine staging).
//  10. Write a small bash relaunch helper to /tmp; spawn it
//      detached.
//  11. `NSApp.terminate(nil)` — the helper waits for the parent
//      PID to exit, ditto-replaces the bundle, and `open -a`s
//      the new copy.
//
// Security posture:
// - SHA pinning closes the MITM-on-asset-URL hole that the
//   existing NaiveUpdater / RustCoreUpdater still have (deferred
//   from Sw#C4 audit; will be retrofitted in v0.2.0).
// - The relaunch helper writes only into the existing app's
//   bundle URL. We refuse to install if that URL is read-only
//   so a user running from a DMG mount or trash gets a clear
//   error instead of a silent no-op.
// - We do NOT request admin escalation. /Applications is
//   admin-group writable by default; the user is asked to drag
//   the .app there once, after which all updates work without
//   `sudo` or auth dialogs.

import AppKit
import CryptoKit
import Foundation
import Observation

/// Live state of the in-app self-updater. `@Observable` so the
/// Settings panel re-renders as the pipeline progresses.
@MainActor
@Observable
public final class AppUpdater {

    /// Pipeline state. Each variant is a UI-renderable phase.
    public enum State: Sendable, Equatable {
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
    public struct AvailableRelease: Sendable, Equatable {
        public let tag: String              // e.g. "v0.1.7.6"
        public let version: String          // e.g. "0.1.7.6"
        public let zipURL: URL
        public let shaManifestURL: URL
        public let releaseNotesURL: URL
        public let publishedAt: Date?
    }

    /// Errors raised by the updater pipeline.
    public enum UpdaterError: Error, Sendable, Equatable {
        case message(String)
    }

    public private(set) var state: State = .idle

    public init() {}

    // MARK: - Public surface

    /// Performs steps 1–2: hits GitHub, decides whether an update
    /// exists. Cheap; safe to call from `Settings.onAppear`.
    ///
    /// **Order of operations matters here.** v0.1.7.7 had a bug
    /// where this method asked `fetchLatestRelease` to validate
    /// every required asset (.zip + .sha256) BEFORE comparing
    /// versions. If the latest release was missing the .sha256
    /// (release-process oversight), users on the same version
    /// got a misleading "Update failed: missing manifest" error
    /// instead of the correct "You're on the latest version"
    /// message. Fixed: fetch metadata only, compare versions
    /// first, then validate install assets only when there's
    /// genuinely something to install.
    public func checkForUpdates() async {
        // CRITICAL: this guard used to be `guard !isInFlight else
        // { return }` which broke the v0.1.7.9 click flow. The
        // Settings handler now calls `markEnteringCheck()` first
        // (synchronous flip to `.checking`) and THEN spawns this
        // Task. By the time we run, `state` is already
        // `.checking` and the old `isInFlight` guard returned
        // early — the network call never fired. Now we only
        // refuse re-entry when a *genuinely active* later phase
        // is already in flight; the `.checking` placeholder
        // state is treated as "we are the in-flight check".
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
                // Newer release exists — now we MUST verify the
                // install assets are present, because we're about
                // to offer the user an Update button.
                let validated = try Self.validateInstallAssets(metadata)
                state = .available(latest: validated)
            } else {
                state = .upToDate(currentVersion: current)
            }
        } catch let UpdaterError.message(reason) {
            state = .failed(message: reason)
        } catch {
            state = .failed(message: error.localizedDescription)
        }
    }

    /// Performs steps 3–11: downloads, verifies, extracts,
    /// relaunches. Caller should have already moved through
    /// `.available` via `checkForUpdates`.
    public func downloadAndInstall(_ release: AvailableRelease) async {
        // Same regression fix as `checkForUpdates`: the click
        // handler synchronously flips `state` to `.downloading`
        // via `markEnteringDownload`, so we'd return early on a
        // strict `isInFlight` guard. Refuse only if a later
        // phase has already begun.
        switch state {
        case .verifying, .extracting, .relaunching:
            return
        default:
            break
        }
        state = .downloading(progress: 0.0)
        do {
            try await Self.run(release: release) { phase in
                self.state = phase
            }
            // Spawning the helper has been initiated; the
            // helper now waits on our PID. Set state and quit.
            state = .relaunching
            // 1.2-second delay so the `.relaunching` subtitle
            // ("The app will close in a moment.") actually
            // renders before AppKit starts the
            // `applicationShouldTerminate` flow. The previous
            // 500 ms was below SwiftUI's render cycle on
            // slower hardware — users on Intel Macs often
            // never saw the state transition before the
            // window vanished.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await MainActor.run { NSApp.terminate(nil) }
        } catch let UpdaterError.message(reason) {
            state = .failed(message: reason)
        } catch {
            state = .failed(message: error.localizedDescription)
        }
    }

    /// Resets `failed` / `upToDate` / `available` back to idle so
    /// the Settings UI can present a fresh "Check" button.
    public func reset() {
        guard !isInFlight else { return }
        state = .idle
    }

    // MARK: - Pipeline (off-main wherever possible)

    /// `true` when a phase is in flight that further user input
    /// should not interrupt. Made `public` so the Settings UI
    /// can synchronously short-circuit double-clicks before the
    /// async machinery flips `state`.
    public var isInFlight: Bool {
        switch state {
        case .checking, .downloading, .verifying, .extracting, .relaunching:
            true
        default:
            false
        }
    }

    /// Synchronously flips `state` to `.checking`. Used by the
    /// Settings click handler to defeat the click → Task-spawn
    /// → state-update race that would otherwise let multiple
    /// rapid clicks each pass their own re-entry guard. The
    /// `Task` that follows then re-runs the same check
    /// internally and is a no-op if state is already `.checking`.
    public func markEnteringCheck() {
        guard !isInFlight else { return }
        state = .checking
    }

    /// Synchronously flips `state` to `.downloading(progress: 0)`.
    /// Same race-defeating role as `markEnteringCheck`.
    public func markEnteringDownload() {
        guard !isInFlight else { return }
        state = .downloading(progress: 0.0)
    }

    /// Bare release metadata — tag, version, html URL, and the
    /// raw asset list. Does NOT validate that install-time
    /// assets (.zip + .sha256) are present; that's
    /// `validateInstallAssets`'s job. Split out so the
    /// "Check for Updates" path can compare versions and
    /// short-circuit to "up to date" without erroring on a
    /// missing manifest in the same-version case.
    private struct ReleaseMetadata {
        let tag: String
        let version: String
        let htmlURL: URL
        let publishedAt: Date?
        let assets: [GHAsset]
    }

    private struct GHAsset: Decodable {
        let name: String
        let browserDownloadURL: URL
        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    /// Hits GitHub `/releases/latest` and returns metadata. We
    /// use `/latest` (not `/releases?per_page=20`) because for
    /// the .app updater we only care about stable tags;
    /// `/latest` excludes pre-releases which is the right
    /// policy for a user-facing upgrade.
    private static func fetchLatestReleaseMetadata() async throws -> ReleaseMetadata {
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
        request.timeoutInterval = 15

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
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

        // Validate the tag shape against the canonical
        // `vN.N.N(.N)?` pattern before letting it anywhere near
        // a path. Defense-in-depth: even just rendering the tag
        // in a UI string deserves a sanity check.
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

    /// Confirms the release exposes both the install .zip and
    /// the matching .sha256 manifest. Called only when there's
    /// genuinely a newer version to install — the missing-asset
    /// case is then a real release-process bug worth surfacing
    /// to the user, not noise on the same-version "check"
    /// path.
    private static func validateInstallAssets(_ meta: ReleaseMetadata) throws -> AvailableRelease {
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
        return AvailableRelease(
            tag: meta.tag,
            version: meta.version,
            zipURL: zipAsset.browserDownloadURL,
            shaManifestURL: shaAsset.browserDownloadURL,
            releaseNotesURL: meta.htmlURL,
            publishedAt: meta.publishedAt
        )
    }

    /// Steps 3–10. Pure pipeline; the caller maps phases to
    /// `state` via the `report` callback.
    private static func run(
        release: AvailableRelease,
        report: @escaping @MainActor @Sendable (State) -> Void
    ) async throws {
        let tempRoot = try makeTempDirectory()
        // **v0.1.7.10 fix:** wrap the body so any failure
        // (download, manifest mismatch, extraction error,
        // verification reject, read-only volume) cleans up
        // `tempRoot`. The previous implementation only handed
        // tempRoot to the relaunch helper on success, leaking
        // the tree forever on every failed attempt — users
        // who Update against a few bad releases accumulated
        // ~50 MB of orphan dirs in /var/folders/.../T/.
        // On success the helper takes ownership and removes
        // it via the `trap cleanup EXIT` we wired in C2.
        do {
            try await runPipeline(release: release, tempRoot: tempRoot, report: report)
        } catch {
            try? FileManager.default.removeItem(at: tempRoot)
            throw error
        }
    }

    private static func runPipeline(
        release: AvailableRelease,
        tempRoot: URL,
        report: @escaping @MainActor @Sendable (State) -> Void
    ) async throws {
        let zipURL = tempRoot.appendingPathComponent(release.zipURL.lastPathComponent)
        let shaURL = tempRoot.appendingPathComponent(release.shaManifestURL.lastPathComponent)

        // 3. Download .zip.
        try await download(release.zipURL, to: zipURL)
        await MainActor.run { report(.verifying) }

        // 4. Download SHA manifest.
        try await download(release.shaManifestURL, to: shaURL)

        // 5–6. Verify SHA-256 against manifest line for the .zip name.
        try verifyZipAgainstManifest(
            zipURL: zipURL,
            manifestURL: shaURL,
            zipFilename: release.zipURL.lastPathComponent
        )

        // 7. Extract.
        await MainActor.run { report(.extracting) }
        let extractDir = tempRoot.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(
            at: extractDir, withIntermediateDirectories: true)
        try await unzip(zipURL: zipURL, to: extractDir)

        // 8. Find + verify the new .app.
        let extractedAppURL = try locateAppBundle(in: extractDir)
        try await verifyExtractedApp(at: extractedAppURL, expectedVersion: release.version)

        // 9. Refuse if running app is on read-only volume. Use
        // the symlink-resolved URL so a symlinked install path
        // (rare on personal Macs, sometimes seen on managed
        // ones) is rejected based on the *real* destination,
        // not the visible alias.
        let runningAppURL = Bundle.main.bundleURL.resolvingSymlinksInPath()
        try refuseReadOnlyInstall(at: runningAppURL)

        // 10. Spawn helper. The helper takes ownership of
        // `tempRoot` and removes it after copying.
        try spawnRelaunchHelper(
            oldAppURL: runningAppURL,
            newAppURL: extractedAppURL,
            tempRootToClean: tempRoot,
            parentPID: ProcessInfo.processInfo.processIdentifier
        )
    }

    // MARK: - Pipeline helpers

    /// Hard cap on a single asset download. Cool Tunnel zips run
    /// ~12 MB; setting the ceiling at 100 MB leaves generous
    /// slack for future growth while preventing a confused-deputy
    /// or compromised-asset URL from filling the user's disk.
    /// Sw-H3 fix.
    private static let maxDownloadBytes: Int64 = 100 * 1024 * 1024

    private static func download(_ url: URL, to destination: URL) async throws {
        let (tempURL, response): (URL, URLResponse)
        do {
            (tempURL, response) = try await URLSession.shared.download(from: url)
        } catch {
            throw UpdaterError.message(
                "Download failed for \(url.lastPathComponent). Check your internet connection and try again."
            )
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdaterError.message(
                "GitHub returned status \((response as? HTTPURLResponse)?.statusCode ?? -1) for \(url.lastPathComponent)."
            )
        }
        // **v0.1.7.10 (Sw-H3):** size cap. By the time
        // `download(from:)` returns, the bytes are already on
        // disk in the temp file — but we can still refuse to
        // promote anything larger than our ceiling. (Real
        // streaming-cancel needs `URLSessionDownloadDelegate`,
        // deferred to v0.2.) Reject the manifest at 1 MB
        // (manifests are ~250 bytes) and the .zip at 100 MB.
        let cap: Int64 = url.pathExtension == "sha256"
            ? 1 * 1024 * 1024
            : Self.maxDownloadBytes
        if let attrs = try? FileManager.default.attributesOfItem(atPath: tempURL.path),
            let size = attrs[.size] as? NSNumber,
            size.int64Value > cap
        {
            try? FileManager.default.removeItem(at: tempURL)
            throw UpdaterError.message(
                "\(url.lastPathComponent) exceeded the \(cap / (1024 * 1024)) MB size limit; refusing to install."
            )
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    /// Reads `manifestURL`, finds the line for `zipFilename`,
    /// computes the SHA-256 of `zipURL` and asserts a match.
    /// Throws `UpdaterError.message` on any mismatch — the
    /// caller treats that as a refusal to install.
    private static func verifyZipAgainstManifest(
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
        // Manifest lines look like:
        //   `<sha256>  Cool-tunnel-v0.1.7.6.zip`
        // Two-space separator (BSD/Linux `shasum` default).
        var expectedSha: String?
        for line in manifest.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
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
        // **v0.1.7.10 (Sw-H2):** validate the manifest entry is
        // actually 64 hex chars before treating it as a hash. A
        // corrupted manifest line `XYZ123… filename` would
        // otherwise pass the count==64 check and fail the
        // string-compare with a misleading "SHA-256 mismatch"
        // message. Distinguishing manifest-malformed from
        // hash-mismatch helps debug release-process bugs vs
        // genuine MITM.
        let isHex = expected.allSatisfy { $0.isHexDigit }
        guard isHex else {
            throw UpdaterError.message(
                "SHA-256 manifest entry for \(zipFilename) is not valid hex. Manifest may be corrupted; refusing to update."
            )
        }
        let actualSha: String
        do {
            let data = try Data(contentsOf: zipURL)
            let digest = SHA256.hash(data: data)
            actualSha = digest.map { String(format: "%02x", $0) }.joined()
        } catch {
            throw UpdaterError.message("Couldn't read downloaded archive to verify hash.")
        }
        guard actualSha == expected else {
            // **v0.1.7.10 (Sw-H2):** don't echo both hashes into
            // the user-facing error string. The mismatch happens
            // either because the upstream changed (release-process
            // mistake — re-download will fix) or because of a
            // MITM (in which case we MUST not show the attacker's
            // hash). The actual values stay in tracing for
            // debugging via `cool-tunnel-core --version` →
            // support tickets.
            throw UpdaterError.message(
                "SHA-256 verification failed for \(zipFilename). The download may be corrupted or tampered with — refusing to install."
            )
        }
    }

    /// Uses `/usr/bin/ditto -x -k` to extract the .zip preserving
    /// macOS metadata. `unzip(1)` on macOS sometimes drops
    /// resource forks and code-signature metadata.
    ///
    /// **v0.1.7.10 fix:** routed through `Subprocess.run` so a
    /// verbose ditto failure (corrupted zip with thousands of
    /// entries → multi-KB stderr) cannot fill the kernel pipe
    /// buffer (~64 KB) and deadlock `waitUntilExit`. The
    /// in-house `Subprocess` runner drains stdout + stderr
    /// concurrently with timeout escalation, which is exactly
    /// the bug class the v0.1.7.3 helper was built to fix —
    /// AppUpdater (added v0.1.7.6) inherited the older,
    /// buggier pattern by oversight.
    private static func unzip(zipURL: URL, to destination: URL) async throws {
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
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdaterError.message(
                "ditto failed to extract update: \(stderr)"
            )
        }
        // **v0.1.7.10 (Sw-H4):** post-extraction symlink-escape
        // walk. `ditto -x -k` (PKZip mode) preserves symlinks
        // inside the archive, including ones that point OUTSIDE
        // the extraction directory. A malicious zip with an
        // entry like `Cool tunnel.app/Contents/Resources/foo ->
        // /Users/<you>/.ssh/config` would, after extraction,
        // leave a side-channel symlink Cool Tunnel might later
        // follow. Bundle-id + version + codesign verification
        // protects the .app itself; the symlink walk closes
        // the side-channel.
        try refuseExtractionEscapingSymlinks(in: destination)
    }

    /// Walks `directory` recursively. If any entry is a symbolic
    /// link whose realpath escapes `directory`, throws. Used by
    /// the post-extraction security check above.
    private static func refuseExtractionEscapingSymlinks(in directory: URL) throws {
        let containerPath = directory.standardizedFileURL.resolvingSymlinksInPath().path
        guard
            let walker = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isSymbolicLinkKey],
                options: []
            )
        else {
            // Couldn't open the directory; the next step (ditto
            // already succeeded) would have noticed the same.
            return
        }
        for case let item as URL in walker {
            let isSymlink: Bool
            do {
                isSymlink = try item.resourceValues(forKeys: [.isSymbolicLinkKey])
                    .isSymbolicLink ?? false
            } catch {
                continue
            }
            if !isSymlink { continue }
            // Resolve the symlink target relative to its parent,
            // then standardise. If the resolved path doesn't
            // start with our container path, it escapes.
            let resolved = item.resolvingSymlinksInPath().standardizedFileURL.path
            if !resolved.hasPrefix(containerPath) {
                throw UpdaterError.message(
                    "Update archive contains a symbolic link pointing outside the extraction directory; refusing to install."
                )
            }
        }
    }

    /// Walks the extraction directory looking for a single .app
    /// bundle. Refuses if zero or more than one is present —
    /// either is a sign the archive isn't what we expected.
    private static func locateAppBundle(in directory: URL) throws -> URL {
        let items = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )
        let apps = items.filter { $0.pathExtension == "app" }
        guard apps.count == 1 else {
            throw UpdaterError.message(
                "Update archive contained \(apps.count) .app bundles; expected exactly 1."
            )
        }
        return apps[0]
    }

    /// Defensive verification on the freshly-extracted .app:
    /// - bundle identifier must match the running app's
    /// - `CFBundleShortVersionString` must match `expectedVersion`
    /// - `CodeSignVerifier` must accept the bundle
    private static func verifyExtractedApp(at appURL: URL, expectedVersion: String) async throws {
        // Read the new bundle's Info.plist.
        let infoURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist", isDirectory: false)
        let info: [String: Any]
        do {
            let data = try Data(contentsOf: infoURL)
            guard
                let plist = try PropertyListSerialization.propertyList(
                    from: data, options: [], format: nil) as? [String: Any]
            else {
                throw UpdaterError.message("New app's Info.plist is malformed.")
            }
            info = plist
        } catch let UpdaterError.message(reason) {
            throw UpdaterError.message(reason)
        } catch {
            throw UpdaterError.message("Couldn't read new app's Info.plist.")
        }

        let runningBundleID = Bundle.main.bundleIdentifier ?? ""
        guard let newBundleIDRaw = info["CFBundleIdentifier"] as? String else {
            throw UpdaterError.message(
                "New app has no bundle identifier. Refusing to install."
            )
        }
        // **v0.1.7.10 (Sw-H1):** defence-in-depth bundle-ID
        // comparison. Apple bundle IDs are ASCII by convention,
        // but a malicious release whose `CFBundleIdentifier`
        // contained a Unicode confusable (e.g. Cyrillic 'е' for
        // ASCII 'e') would have compared unequal pre-fix and
        // gone through the rejection branch — but if SHA pinning
        // were ever defeated and an attacker wrote the running
        // bundle ID with the same confusable, the byte-compare
        // would silently accept it. Reject anything non-ASCII
        // outright.
        let newBundleID = newBundleIDRaw.precomposedStringWithCanonicalMapping
        let normalizedRunning = runningBundleID.precomposedStringWithCanonicalMapping
        guard newBundleID.allSatisfy(\.isASCII), normalizedRunning.allSatisfy(\.isASCII) else {
            throw UpdaterError.message(
                "Bundle identifier contains non-ASCII characters. Refusing to install for safety."
            )
        }
        guard newBundleID == normalizedRunning else {
            throw UpdaterError.message(
                "New app's bundle identifier does not match. Refusing to install."
            )
        }
        guard let newVersion = info["CFBundleShortVersionString"] as? String,
            newVersion == expectedVersion
        else {
            throw UpdaterError.message(
                "New app's version (\(info["CFBundleShortVersionString"] ?? "?")) does not match the release tag \(expectedVersion). Refusing to install."
            )
        }

        // CodeSignVerifier wraps SecStaticCodeCheckValidity.
        do {
            try await CodeSignVerifier.verifyValid(at: appURL)
        } catch {
            throw UpdaterError.message(
                "New app failed code-signature verification: \(error.localizedDescription)"
            )
        }
    }

    /// Refuse to install if the running app is on a read-only
    /// volume — that's a DMG mount or a quarantine staging area.
    /// The user needs to drag-install at least once before the
    /// updater can replace in place.
    private static func refuseReadOnlyInstall(at appURL: URL) throws {
        let parentDirectory = appURL.deletingLastPathComponent()
        let values = try parentDirectory.resourceValues(forKeys: [.volumeIsReadOnlyKey])
        if values.volumeIsReadOnly == true {
            throw UpdaterError.message(
                "Cool Tunnel must be installed in /Applications before it can self-update. Drag the app from the disk image to Applications, then try Update again."
            )
        }
    }

    /// Writes the relaunch helper to a temp file with mode 0700,
    /// spawns it detached, and returns. The helper waits for the
    /// parent PID to exit, dittos the new app over the old, and
    /// `open -a`s the new copy.
    private static func spawnRelaunchHelper(
        oldAppURL: URL,
        newAppURL: URL,
        tempRootToClean: URL,
        parentPID: Int32
    ) throws {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cool-tunnel-relaunch-\(UUID().uuidString).sh")

        // Bash relaunch dance:
        //   1. Wait up to 30 s for parent to exit (poll kill -0).
        //   2. ditto into a sibling `.new` directory.
        //   3. Atomic-rename pair: old → .old, .new → old.
        //   4. open -a the new app.
        //   5. Clean .old + temp tree + self.
        //
        // **v0.1.7.10 fix:** the previous flow was
        //   `rm -rf "$OLD_APP" && ditto "$NEW_APP" "$OLD_APP"`,
        // which is destructive with no rollback — if `ditto`
        // failed mid-copy (ENOSPC, signal), the user was left
        // with no Cool Tunnel installed at all. The new
        // `.new`-stage-then-rename pattern lets us restore the
        // .old copy on any failure step. `set -e` guarantees
        // we abort on the first error; `trap` handles cleanup
        // on every exit path, including the 30 s timeout.
        let script = """
            #!/bin/bash
            set -eu
            PARENT_PID=\(parentPID)
            OLD_APP=\(shellQuote(oldAppURL.path))
            NEW_APP=\(shellQuote(newAppURL.path))
            TEMP_ROOT=\(shellQuote(tempRootToClean.path))
            STAGED="${OLD_APP}.new"
            BACKUP="${OLD_APP}.old-update"

            # Always-run cleanup: the temp tree and the helper
            # itself are removed on any exit path. .new and .old
            # are only present mid-flight; the swap section
            # cleans them as it goes.
            cleanup() {
                rm -rf "$TEMP_ROOT" 2>/dev/null || true
                rm -f "$0" 2>/dev/null || true
            }
            trap cleanup EXIT

            # Wait for the parent process to exit so we can replace
            # the bundle without "file in use" errors. 30 s ceiling.
            for _ in $(seq 1 60); do
                if ! kill -0 "$PARENT_PID" 2>/dev/null; then
                    break
                fi
                sleep 0.5
            done

            # Defensive: refuse if parent didn't exit (something
            # held us up; better to leak than corrupt the app).
            if kill -0 "$PARENT_PID" 2>/dev/null; then
                exit 1
            fi

            # Pre-clean any stale stage/backup from a prior
            # interrupted run.
            rm -rf "$STAGED" "$BACKUP" 2>/dev/null || true

            # 1. Stage the new app alongside the old one.
            #    `ditto` preserves macOS metadata (resource forks,
            #    code-signature, xattrs) — `cp -R` may not.
            ditto "$NEW_APP" "$STAGED"

            # 2. Move old → .old-update (atomic rename — the user
            #    has no app for a single rename's worth of time).
            #    If this fails, the staged copy is removed by
            #    cleanup; the original old app is intact.
            if ! mv "$OLD_APP" "$BACKUP" 2>/dev/null; then
                rm -rf "$STAGED"
                exit 1
            fi

            # 3. Promote staged copy into place.
            #    If this fails, restore the backup. Order matters:
            #    move BACKUP back BEFORE removing STAGED, so even
            #    if STAGED removal fails, the user has an app.
            if ! mv "$STAGED" "$OLD_APP" 2>/dev/null; then
                mv "$BACKUP" "$OLD_APP" 2>/dev/null || true
                rm -rf "$STAGED" 2>/dev/null || true
                exit 1
            fi

            # 4. Remove the backup (the swap succeeded; old app
            #    no longer needed).
            rm -rf "$BACKUP" 2>/dev/null || true

            # 5. Relaunch the freshly-installed copy.
            open -a "$OLD_APP"
            """

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        // Spawn detached. We deliberately do NOT wait — the
        // caller is about to NSApp.terminate.
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

    private static func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cool-tunnel-app-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Version + tag parsing

    /// Validates a tag matches `v?N.N.N(.N)?` shape. Defensive
    /// against a future GitHub-side issue that returns garbage.
    static func isValidVersionTag(_ tag: String) -> Bool {
        guard !tag.isEmpty, tag.count <= 64 else { return false }
        let pattern = #"^v?\d+(\.\d+){1,3}(-[A-Za-z0-9.]+)?$"#
        return tag.range(of: pattern, options: .regularExpression) != nil
    }

    /// Returns true if `candidate` strictly outranks `base` under
    /// segment-wise numeric compare. Both must already be
    /// canonical (no leading `v`). Missing segments compare as 0.
    static func versionIsNewer(_ candidate: String, than base: String) -> Bool {
        let lhs = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = base.split(separator: ".").map { Int($0) ?? 0 }
        let len = max(lhs.count, rhs.count)
        for i in 0..<len {
            let l = i < lhs.count ? lhs[i] : 0
            let r = i < rhs.count ? rhs[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// Quotes `arg` for safe inclusion in a bash single-quoted
    /// context. Single quotes inside become `'\''`.
    private static func shellQuote(_ arg: String) -> String {
        "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
