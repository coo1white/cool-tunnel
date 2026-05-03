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
        guard !isInFlight else { return }
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
        guard !isInFlight else { return }
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
        // Defer cleanup AFTER the helper script has been spawned;
        // the helper reads from `extractedAppURL` so we must keep
        // the temp tree alive past this function. Cleanup happens
        // in the helper via `rm -rf` once it copies the new app.
        // (We deliberately do NOT defer-cleanup here.)

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
        try unzip(zipURL: zipURL, to: extractDir)

        // 8. Find + verify the new .app.
        let extractedAppURL = try locateAppBundle(in: extractDir)
        try await verifyExtractedApp(at: extractedAppURL, expectedVersion: release.version)

        // 9. Refuse if running app is on read-only volume.
        let runningAppURL = Bundle.main.bundleURL
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
        let actualSha: String
        do {
            let data = try Data(contentsOf: zipURL)
            let digest = SHA256.hash(data: data)
            actualSha = digest.map { String(format: "%02x", $0) }.joined()
        } catch {
            throw UpdaterError.message("Couldn't read downloaded archive to verify hash.")
        }
        guard actualSha == expected else {
            throw UpdaterError.message(
                "SHA-256 mismatch — expected \(expected), got \(actualSha). Refusing to install."
            )
        }
    }

    /// Uses `/usr/bin/ditto -x -k` to extract the .zip preserving
    /// macOS metadata. `unzip(1)` on macOS sometimes drops
    /// resource forks and code-signature metadata.
    private static func unzip(zipURL: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipURL.path, destination.path]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        do {
            try process.run()
        } catch {
            throw UpdaterError.message("Couldn't launch ditto to extract update.")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: data, encoding: .utf8) ?? ""
            throw UpdaterError.message(
                "ditto failed to extract update: \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
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
        guard let newBundleID = info["CFBundleIdentifier"] as? String,
            newBundleID == runningBundleID
        else {
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
        //   2. ditto-replace the old app with the new one.
        //   3. open -a the new app.
        //   4. Clean the temp tree.
        // Single-quoted heredoc so the Swift-side string literal
        // doesn't clash with bash variable expansion.
        let script = """
            #!/bin/bash
            set -u
            PARENT_PID=\(parentPID)
            OLD_APP=\(shellQuote(oldAppURL.path))
            NEW_APP=\(shellQuote(newAppURL.path))
            TEMP_ROOT=\(shellQuote(tempRootToClean.path))

            # Wait for the parent process to exit so we can replace
            # the bundle without "file in use" errors. 30 s ceiling.
            for _ in $(seq 1 60); do
                if ! kill -0 "$PARENT_PID" 2>/dev/null; then
                    break
                fi
                sleep 0.5
            done

            # Defensive: refuse if parent didn't exit (something held
            # us up; better to leak the temp tree than corrupt the app).
            if kill -0 "$PARENT_PID" 2>/dev/null; then
                exit 1
            fi

            # Replace. ditto preserves macOS metadata (resource
            # forks, code-signature, xattrs) which `cp -R` may not.
            rm -rf "$OLD_APP"
            ditto "$NEW_APP" "$OLD_APP"

            # Relaunch the freshly-installed copy.
            open -a "$OLD_APP"

            # Tidy up the temp tree the Swift side handed us.
            rm -rf "$TEMP_ROOT"

            # Self-delete the helper (best effort).
            rm -f "$0"
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
