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
//   5. Compute SHA-256 of the downloaded .zip via CryptoKit
//      (streamed from disk; AU-4 fix avoids loading the whole
//      .zip into memory on @MainActor).
//   6. Cross-reference against the manifest line for the .zip
//      filename. Refuse on mismatch.
//   7. Extract via `ditto -x -k` (through `Subprocess.run` for
//      concurrent pipe drain + timeout escalation).
//   8. Verify the extracted `Cool tunnel.app`:
//      - Bundle identifier matches the running app's.
//      - `CFBundleShortVersionString` matches the release tag.
//      - `CodeSignVerifier` accepts the bundle.
//   9. Refuse if the running app is on a read-only volume (DMG
//      mount or quarantine staging).
//  10. Write a small bash relaunch helper into the per-update
//      tempRoot (NOT /tmp — see AU-1) atomically with mode
//      0700, then spawn it detached.
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
//
// ## v0.1.7.11 Rule-Maker hardening (Fifth audit cycle)
//
// - **AU-1 (R2, R4):** the relaunch helper script no longer
//   lives in `/tmp`. Previously `String.write(to:atomically:)`
//   created the file with default umask perms (typically 0644),
//   then a separate `setAttributes(0o700)` call tightened them —
//   leaving a tiny but real window where a same-UID attacker
//   could swap the script via symlink before `task.run()`. The
//   script now lives in the per-update `tempRoot` (already
//   created with restrictive perms), and is created via
//   `open(O_CREAT|O_EXCL|O_WRONLY, 0o700)` so it is born with
//   the right mode and never exists with any other.
// - **AU-2 (R2):** `browser_download_url`s returned by the
//   GitHub releases API are now validated against an HTTPS +
//   github.com / githubusercontent.com host suffix list before
//   being handed to `URLSession.download`. Previously a
//   compromised or changed API response could redirect the
//   .zip / manifest fetch to an attacker-controlled host;
//   SHA pinning protects the .zip but TRUSTS the manifest URL
//   (it defines the expected hash), so the manifest URL is the
//   actual root of trust.
// - **AU-3 (R2):** all GitHub fetches now use a per-task
//   delegate that constrains HTTP redirects to the same host
//   suffix list. `URLSession.shared.download(from:)` was
//   following up to ~20 redirects with no host check — a CDN
//   takeover or misconfigured GitHub redirect could substitute
//   the manifest at this layer, defeating SHA pinning.
// - **AU-4 (R3):** SHA hashing and Info.plist parsing have
//   been moved off `@MainActor`. The pipeline helpers are now
//   `nonisolated`, and `verifyZipAgainstManifest` streams the
//   .zip through `FileHandle.read(upToCount:)` 64 KiB at a
//   time instead of `Data(contentsOf: zipURL)` which previously
//   loaded the full ~12 MB into memory on the main thread.
// - **AU-5 (R2, R4):** `refuseExtractionEscapingSymlinks` no
//   longer uses `String.hasPrefix` (which gives false negatives
//   for sibling paths like `/extracted-evil` vs `/extracted`,
//   and doesn't normalise `..`-traversal through symlink
//   targets). It now uses `realpath(3)` + path-component
//   ancestor comparison.
// - **AU-7 (R1):** the version-mismatch error in
//   `verifyExtractedApp` no longer interpolates the new app's
//   `CFBundleShortVersionString` into the user-facing string.
//   That value is attacker-controlled; an attacker who got past
//   SHA pinning could plant a Unicode-bidi-override or fake
//   "click here to bypass" text in it. The actual value still
//   goes to `os_log` for support tickets.
// - **AU-12 (R1, R2):** `versionIsNewer` no longer silently
//   coerces non-numeric segments to 0 via `Int($0) ?? 0`.
//   Pre-release suffixes (`-rc1`, `-beta`) are now an outright
//   reject signal — `/releases/latest` already excludes them,
//   so seeing one is a release-process bug, not a normal upgrade.
// - **AU-15 (R2):** `public` access has been removed from
//   symbols that are only consumed within the same module
//   (Settings UI). `internal` (the default) is sufficient and
//   shrinks the API surface that future code paths can
//   accidentally reach.

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
        let tag: String              // e.g. "v0.1.7.6"
        let version: String          // e.g. "0.1.7.6"
        let zipURL: URL
        let shaManifestURL: URL
        let releaseNotesURL: URL
        let publishedAt: Date?
    }

    /// Errors raised by the updater pipeline.
    enum UpdaterError: Error, Sendable, Equatable {
        case message(String)
    }

    private(set) var state: State = .idle

    init() {}

    // MARK: - Public surface (within-module; AU-15 demoted from `public`)

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
    func checkForUpdates() async {
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
    func downloadAndInstall(_ release: AvailableRelease) async {
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

    /// Synchronously flips `state` to `.checking` and returns
    /// `true` IFF the caller should proceed to spawn the async
    /// follow-up `Task`. Returning the gate decision (rather
    /// than just flipping state and trusting the caller's own
    /// `isInFlight` check) closes the AU-13 race: a second
    /// click between the no-op `markEnteringCheck` and the
    /// `Task` spawn would otherwise queue two concurrent
    /// network requests.
    ///
    /// **Q-F#1:** `@discardableResult` is intentionally absent
    /// — the caller MUST consume the bool. Without this
    /// constraint a future site that wrote
    /// `appUpdater.markEnteringCheck(); Task { … }` would
    /// reintroduce the race silently (no compiler warning).
    /// Now the type system enforces the design: `Bool` returns
    /// that aren't bound or branched on emit `result of call
    /// is unused` warnings, surfacing the bug at review time.
    func markEnteringCheck() -> Bool {
        if isInFlight { return false }
        state = .checking
        return true
    }

    /// Synchronously flips `state` to `.downloading(progress: 0)`
    /// and returns `true` IFF the caller should proceed. Same
    /// AU-13 race-defeating role as `markEnteringCheck`; same
    /// Q-F#1 reasoning for the missing `@discardableResult`.
    func markEnteringDownload() -> Bool {
        if isInFlight { return false }
        state = .downloading(progress: 0.0)
        return true
    }

    // MARK: - Pipeline (off-main; nonisolated by design)

    /// Bare release metadata — tag, version, html URL, and the
    /// raw asset list. Does NOT validate that install-time
    /// assets (.zip + .sha256) are present; that's
    /// `validateInstallAssets`'s job. Split out so the
    /// "Check for Updates" path can compare versions and
    /// short-circuit to "up to date" without erroring on a
    /// missing manifest in the same-version case.
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

    /// Hits GitHub `/releases/latest` and returns metadata. We
    /// use `/latest` (not `/releases?per_page=20`) because for
    /// the .app updater we only care about stable tags;
    /// `/latest` excludes pre-releases which is the right
    /// policy for a user-facing upgrade.
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
        request.timeoutInterval = 15

        // **AU-3:** per-task delegate constrains any HTTP
        // redirect to the trusted GitHub host suffixes.
        // **E-F#3 / R-F#4:** shared singleton (no per-request
        // allocation), shared with NaiveUpdater + RustCoreUpdater.
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
    /// the matching .sha256 manifest, AND that both asset URLs
    /// point at trusted GitHub-served hosts (AU-2). Called only
    /// when there's genuinely a newer version to install.
    nonisolated private static func validateInstallAssets(_ meta: ReleaseMetadata) throws -> AvailableRelease {
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
        // **AU-2:** validate both URLs point at trusted GitHub
        // hosts before letting them through to URLSession.
        // browser_download_url has historically resolved to
        // github-releases.githubusercontent.com via redirect;
        // direct values that aren't on github.com /
        // *.githubusercontent.com are a sign of an attacker-
        // shaped API response or an upstream change we should
        // pause for, not trust silently.
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

    /// Steps 3–10. Pure pipeline; the caller maps phases to
    /// `state` via the `report` callback.
    nonisolated private static func run(
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

    nonisolated private static func runPipeline(
        release: AvailableRelease,
        tempRoot: URL,
        report: @escaping @MainActor @Sendable (State) -> Void
    ) async throws {
        let zipURL = tempRoot.appendingPathComponent(release.zipURL.lastPathComponent)
        let shaURL = tempRoot.appendingPathComponent(release.shaManifestURL.lastPathComponent)

        // **E-F#1:** the .zip and .sha256 fetches are independent
        // (the manifest doesn't gate the .zip request — both URLs
        // come from the already-validated GitHub release JSON).
        // Previously they ran serially, costing ~12 MB + ~250 B
        // back-to-back ≈ same wall-time as the .zip alone × 2.
        // `async let` joins them in parallel; the manifest fetch
        // typically completes during the .zip's TLS handshake.
        async let zipDownload: () = download(release.zipURL, to: zipURL)
        async let shaDownload: () = download(release.shaManifestURL, to: shaURL)
        try await (zipDownload, shaDownload)
        await MainActor.run { report(.verifying) }

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
        let runningAppURL = await MainActor.run { Bundle.main.bundleURL.resolvingSymlinksInPath() }
        try refuseReadOnlyInstall(at: runningAppURL)

        // 10. Spawn helper. The helper takes ownership of
        // `tempRoot` and removes it after copying.
        let parentPID = ProcessInfo.processInfo.processIdentifier
        try spawnRelaunchHelper(
            oldAppURL: runningAppURL,
            newAppURL: extractedAppURL,
            tempRootToClean: tempRoot,
            parentPID: parentPID
        )
    }

    // MARK: - Pipeline helpers

    /// Hard cap on a single asset download. Cool Tunnel zips run
    /// ~12 MB; setting the ceiling at 100 MB leaves generous
    /// slack for future growth while preventing a confused-deputy
    /// or compromised-asset URL from filling the user's disk.
    /// Sw-H3 fix.
    nonisolated private static let maxDownloadBytes: Int64 = 100 * 1024 * 1024

    nonisolated private static func download(_ url: URL, to destination: URL) async throws {
        // **AU-3 / R-F#4:** per-task delegate constrains any
        // redirect to trusted GitHub-served hosts. Shared
        // singleton with NaiveUpdater + RustCoreUpdater so
        // the trust boundary lives in one place.
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
            // **AU-8 (R1):** the user-visible message no longer
            // names the failing artifact (.zip vs .sha256) or
            // the HTTP status. Stage-specific detail goes to
            // os_log for support.
            appUpdaterLogger.info(
                "download non-200 for \(url.lastPathComponent, privacy: .public): \((response as? HTTPURLResponse)?.statusCode ?? -1, privacy: .public)"
            )
            throw UpdaterError.message(
                "GitHub didn't return the update files. Try again later."
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
        // **E-F#6:** drop the fileExists/removeItem pre-check
        // pair (TOCTOU + redundant). `tempRoot` is freshly
        // mkdtemp'd per pipeline run; destination collision
        // is impossible by construction. If a future caller
        // ever passes a pre-existing destination, switch to
        // `replaceItemAt(_:with:)` which is atomic.
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    /// Reads `manifestURL`, finds the line for `zipFilename`,
    /// computes the SHA-256 of `zipURL` and asserts a match.
    /// Throws `UpdaterError.message` on any mismatch — the
    /// caller treats that as a refusal to install.
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
        // **AU-4:** stream the .zip through `FileHandle` 64 KiB
        // at a time instead of `Data(contentsOf: zipURL)`. A
        // 12 MB allocation on the main thread (which runPipeline
        // formerly ran on, before being marked `nonisolated`)
        // could freeze the Settings UI for ~200 ms on slow
        // disks; on Intel Macs with HDDs the user sometimes
        // saw a beach ball. Streaming SHA fixes both axes
        // (background actor + bounded memory).
        let actualSha: String
        do {
            actualSha = try sha256(of: zipURL)
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

    /// Streams `fileURL` through CryptoKit's incremental SHA-256
    /// in 64 KiB chunks. AU-4: avoids `Data(contentsOf:)` which
    /// loads the full file into memory and (when this method ran
    /// on @MainActor) froze the UI on slow disks.
    nonisolated private static func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
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

    /// **E-F#8 (R2):** hard cap on the number of symbolic links
    /// the extraction-walker will canonicalise per archive. An
    /// attacker-shaped zip could plant 10k+ symlinks (each ~30
    /// bytes; the 100 MB Sw-H3 zip cap allows ~3M empty-target
    /// entries). Without a count cap the loop performs one
    /// `realpath(3)` syscall per entry, an attacker-controlled
    /// work multiplier on the user's update path. 1024 is far
    /// above any legitimate macOS .app bundle (counts in the
    /// low double digits) — exceeding it is a structural
    /// anomaly that justifies a refuse-and-bail.
    nonisolated private static let maxExtractionSymlinks: Int = 1024

    /// Walks `directory` recursively. If any entry is a symbolic
    /// link whose realpath escapes `directory`, throws. AU-5
    /// (path-component ancestor check) + E-F#8 (entry-count cap)
    /// + R-F#7 (extracted realpath helper).
    nonisolated private static func refuseExtractionEscapingSymlinks(in directory: URL) throws {
        // Resolve the container to its canonical absolute path
        // so the ancestor check is robust against any symlinks
        // in the tempdir hierarchy (e.g. /var → /private/var on
        // macOS).
        let containerComponents = try canonicalPathComponents(
            of: directory.path,
            errorMessage: "Couldn't canonicalise extraction directory; refusing to install."
        )

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
        var symlinksSeen = 0
        for case let item as URL in walker {
            let isSymlink: Bool
            do {
                isSymlink = try item.resourceValues(forKeys: [.isSymbolicLinkKey])
                    .isSymbolicLink ?? false
            } catch {
                continue
            }
            if !isSymlink { continue }
            // E-F#8: bail before doing the realpath syscall on a
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
            // realpath follows the link AND resolves all interior
            // links + `..` segments — the only way to detect a
            // target like `link/../../etc/passwd`. Broken-link
            // case (realpath returns nil) is treated as reject:
            // an update bundle has no business carrying dangling
            // symlinks.
            let targetComponents = try canonicalPathComponents(
                of: item.path,
                errorMessage:
                    "Update archive contains a broken symbolic link; refusing to install."
            )
            // Component-wise ancestor check. Defeats both the
            // trailing-slash false positive (`/extracted-evil` vs
            // `/extracted`) and any symlink-traversal-via-target.
            guard targetComponents.starts(with: containerComponents) else {
                throw UpdaterError.message(
                    "Update archive contains a symbolic link pointing outside the extraction directory; refusing to install."
                )
            }
        }
    }

    /// **R-F#7:** shared realpath wrapper for `refuseExtraction
    /// EscapingSymlinks`. Wraps the `realpath(3)` syscall +
    /// `String(cString:)` conversion + `free` + `URL.path
    /// Components` extraction in one place; used for both the
    /// container path (once per call) and each symlink target
    /// (per-entry, capped by `maxExtractionSymlinks`). The
    /// `errorMessage` parameter lets the two callers attribute
    /// failure differently while sharing the canonicalisation
    /// primitive.
    nonisolated private static func canonicalPathComponents(
        of path: String,
        errorMessage: String
    ) throws -> [String] {
        guard let cStr = realpath(path, nil) else {
            throw UpdaterError.message(errorMessage)
        }
        defer { free(cStr) }
        return URL(fileURLWithPath: String(cString: cStr)).pathComponents
    }

    /// Walks the extraction directory looking for a single .app
    /// bundle. Refuses if zero or more than one is present —
    /// either is a sign the archive isn't what we expected.
    ///
    /// **AU-14 fix:** the filter now also asserts the entry is
    /// a directory. A malicious zip can contain an entry named
    /// `Cool tunnel.app` that is a regular file or symlink (not
    /// a bundle directory). Without this check, the next step
    /// (`verifyExtractedApp` reading `Contents/Info.plist`)
    /// would fail with the generic "Couldn't read Info.plist"
    /// message instead of a clean "structural shape wrong"
    /// reject. Validating the bundle-shape assumption at the
    /// boundary surfaces the right diagnosis.
    nonisolated private static func locateAppBundle(in directory: URL) throws -> URL {
        let items = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        let apps = items.filter { url in
            guard url.pathExtension == "app" else { return false }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey])
                .isDirectory) ?? false
            return isDir
        }
        guard apps.count == 1 else {
            throw UpdaterError.message(
                "Update archive contained \(apps.count) .app bundles; expected exactly 1."
            )
        }
        return apps[0]
    }

    /// Sendable carrier for the two strings `verifyExtractedApp`
    /// pulls out of Info.plist. Lets us read the plist on a
    /// background actor (AU-4) and pass only the strings back —
    /// `[String: Any]` is not Sendable.
    private struct ExtractedAppInfo: Sendable {
        let bundleIdentifier: String
        let shortVersion: String
    }

    /// Defensive verification on the freshly-extracted .app:
    /// - bundle identifier matches the running app's
    /// - `CFBundleShortVersionString` matches `expectedVersion`
    /// - `CodeSignVerifier` accepts the bundle
    nonisolated private static func verifyExtractedApp(at appURL: URL, expectedVersion: String) async throws {
        // Read the new bundle's Info.plist on a background
        // priority task — AU-4. Previously this synchronous
        // I/O ran on @MainActor (because runPipeline was
        // implicitly MainActor-isolated) and could stall the
        // UI on slow disks.
        let infoURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist", isDirectory: false)
        let info = try await readAppInfo(at: infoURL)

        // **AU-6 (R2, R4):** compare the new bundle ID against
        // the **hard-coded canonical constant**, not against
        // `Bundle.main.bundleIdentifier`. The latter reads from
        // the running process's plist — which an attacker who
        // ever managed to substitute the running app would also
        // have written, anchoring the trust comparison in
        // attacker-controlled input. A constant baked into the
        // binary cannot be re-shaped by anyone who hasn't already
        // compromised the build; it is the only thing about the
        // running process safe to use as a comparison anchor.
        // ASCII-only check is preserved as defence-in-depth
        // against Unicode confusable releases that some
        // future code path might handle differently
        // (`==` on `String` is byte-equal, but a future
        // case-insensitive compare or display rendering
        // would not be).
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
        // **AU-7:** the version-mismatch error no longer
        // interpolates `info.shortVersion` (attacker-controlled
        // bytes from the new bundle's plist). An attacker who
        // got past SHA pinning could plant a Unicode
        // bidi-override or fake-instruction text in that
        // string and have it rendered into the Settings panel.
        // The actual mismatch detail goes to os_log for support.
        guard info.shortVersion == expectedVersion else {
            appUpdaterLogger.info(
                "version mismatch: got=\(info.shortVersion, privacy: .public) expected=\(expectedVersion, privacy: .public)"
            )
            throw UpdaterError.message(
                "New app's version does not match the release tag \(expectedVersion). Refusing to install."
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

    /// Reads an Info.plist off the @MainActor and returns only
    /// the two Sendable strings we need. AU-4.
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
            } catch let UpdaterError.message(reason) {
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

    /// Refuse to install if the running app is on a read-only
    /// volume (DMG mount, quarantine staging) OR if the install
    /// directory or the bundle itself is non-writable for the
    /// current user.
    ///
    /// **AU-9 fix:** previously this only checked
    /// `parentDirectory.volumeIsReadOnlyKey`. Two failure modes
    /// slipped through pre-terminate, leaving the user with no
    /// app and no UI to report the failure once
    /// `NSApp.terminate` had fired:
    ///
    ///   1. The bundle was on a writable volume but the user's
    ///      account didn't have write access to /Applications
    ///      (admin ACL, MDM lockdown). The relaunch helper would
    ///      fail at `mv "$OLD_APP" "$BACKUP"`.
    ///   2. The bundle was on a writable volume in a writable
    ///      folder but the bundle itself was immutable (Get Info
    ///      → Locked, or `chflags uchg`). Same failure mode.
    ///
    /// Now: also test `parentDirectory.isWritableKey` and
    /// `appURL.isWritableKey`. Both checks happen *before* the
    /// `NSApp.terminate` so the error round-trips back to the
    /// Settings panel with a recovery hint.
    nonisolated private static func refuseReadOnlyInstall(at appURL: URL) throws {
        let parentDirectory = appURL.deletingLastPathComponent()
        let parentValues = try parentDirectory.resourceValues(
            forKeys: [.volumeIsReadOnlyKey, .isWritableKey]
        )
        if parentValues.volumeIsReadOnly == true {
            throw UpdaterError.message(
                "Cool Tunnel must be installed in /Applications before it can self-update. Drag the app from the disk image to Applications, then try Update again."
            )
        }
        // AU-9 part 1: parent folder writable for this user?
        if parentValues.isWritable == false {
            appUpdaterLogger.info(
                "parent not writable: \(parentDirectory.path, privacy: .public)"
            )
            throw UpdaterError.message(
                "Cool Tunnel can't write to its install location. Check your folder permissions and try Update again."
            )
        }
        // AU-9 part 2: bundle itself writable (not Locked /
        // chflags-immutable)?
        let bundleValues = try appURL.resourceValues(forKeys: [.isWritableKey])
        if bundleValues.isWritable == false {
            appUpdaterLogger.info(
                "bundle not writable: \(appURL.path, privacy: .public)"
            )
            throw UpdaterError.message(
                "Cool Tunnel's bundle is locked. Right-click the app, choose Get Info, uncheck the Locked checkbox, then try Update again."
            )
        }
    }

    /// Writes the relaunch helper script into `tempRootToClean`
    /// (NOT /tmp — see AU-1) atomically with mode 0700, then
    /// spawns it detached. The helper waits for the parent PID
    /// to exit, dittos the new app over the old, and `open -a`s
    /// the new copy.
    nonisolated private static func spawnRelaunchHelper(
        oldAppURL: URL,
        newAppURL: URL,
        tempRootToClean: URL,
        parentPID: Int32
    ) throws {
        // **AU-1 fix:** the helper script lives inside the
        // per-update tempRoot (already restrictive perms; about
        // to be `rm -rf`'d by the script's own EXIT trap),
        // NOT in `/var/folders/.../T/` where multiple users on
        // the machine and same-UID processes could race a
        // symlink swap into the (post-write, pre-chmod) window.
        // The script is created via `open(O_CREAT|O_EXCL|O_WRONLY,
        // 0o700)` so the file is born with the correct mode and
        // never exists with any other.
        let scriptURL = tempRootToClean
            .appendingPathComponent("cool-tunnel-relaunch.sh", isDirectory: false)

        // **Q-F#2:** the helper script's stderr previously went
        // nowhere — `task.standardError = nil` (in the spawn
        // section below) discards it, so AU-11's `preswap_trap`
        // recovery hint never reached the user. The script now
        // redirects its own stderr to a stable log path under
        // `~/Library/Logs/cool-tunnel/relaunch.log` so support
        // can `tail` it after a failed update without needing to
        // know which `/var/folders/.../T/` tempRoot was in
        // play.
        let logURL = try Self.makeRelaunchLogPath()

        // Bash relaunch dance:
        //   1. Wait up to 30 s for parent to exit (poll kill -0).
        //   2. ditto into a sibling `.new` directory.
        //   3. Atomic-rename pair: old → .old, .new → old.
        //   4. Promote staged copy.
        //   5. open the new app.
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
            LOG=\(shellQuote(logURL.path))
            STAGED="${OLD_APP}.new"
            BACKUP="${OLD_APP}.old-update"

            # Q-F#2: redirect script stderr to the user-visible
            # log path. Without this, every `>&2` line in the
            # preswap_trap (and the warm-up echo below) would go
            # to /dev/null because the parent set
            # task.standardError = nil before exiting.
            mkdir -p "$(dirname "$LOG")"
            exec 2>>"$LOG"
            echo "[$(date '+%FT%T%z')] cool-tunnel-relaunch starting (parent=$PARENT_PID)"

            # AU-11 (R4): pre-swap trap. Until step 4 commits the
            # swap, an unexpected exit MUST preserve the recovery
            # materials — both the verified-good extracted copy
            # under $TEMP_ROOT and the $BACKUP if rollback failed
            # mid-step. The user (or a support engineer) can then
            # restore manually. Once the swap commits, this trap
            # is replaced with the destructive cleanup.
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
            #    If this fails, the staged copy is removed; the
            #    original old app is intact; preswap_trap fires.
            if ! mv "$OLD_APP" "$BACKUP" 2>/dev/null; then
                rm -rf "$STAGED"
                exit 1
            fi

            # 3. Promote staged copy into place.
            #    If this fails, restore the backup. Order matters:
            #    move BACKUP back BEFORE removing STAGED, so even
            #    if STAGED removal fails, the user has an app.
            #    preswap_trap will fire; $TEMP_ROOT preserved.
            if ! mv "$STAGED" "$OLD_APP" 2>/dev/null; then
                mv "$BACKUP" "$OLD_APP" 2>/dev/null || true
                rm -rf "$STAGED" 2>/dev/null || true
                exit 1
            fi

            # 4. Remove the backup (the swap succeeded; old app
            #    no longer needed). After this point the new app
            #    is in place — switch to the destructive cleanup
            #    trap so $TEMP_ROOT gets removed on exit. AU-11.
            rm -rf "$BACKUP" 2>/dev/null || true

            cleanup() {
                rm -rf "$TEMP_ROOT" 2>/dev/null || true
            }
            trap cleanup EXIT

            # 5. Relaunch the freshly-installed copy.
            #    AU-10: use `open PATH` (path-based bundle launch)
            #    rather than `open -a NAME` (name-based app
            #    lookup). With bundle paths containing spaces
            #    ("/Applications/Cool tunnel.app") the `-a` form
            #    treats "Cool" as the app name and "tunnel.app"
            #    as a document, misfiring the relaunch. The
            #    bareword form opens the bundle directly.
            open "$OLD_APP"
            """

        try writeRelaunchScript(script, to: scriptURL)

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

    /// AU-1: atomic, race-free helper-script writer.
    ///
    /// Uses `open(O_CREAT | O_EXCL | O_WRONLY, 0o700)` so the
    /// file is created with the restrictive mode in a single
    /// syscall. There is NO window where the file exists with
    /// default umask perms (the previous `String.write` +
    /// `setAttributes` pair did have such a window, ~µs but
    /// real). `O_EXCL` refuses if the file already exists,
    /// which would be a sign of a pre-existing attacker-planted
    /// file in tempRoot — bail in that case.
    /// Atomic, race-free helper-script writer.
    ///
    /// **R-F#1:** delegates to `RestrictedFile.write` — the
    /// shared `O_CREAT|O_EXCL` + write + fsync + atomic-rename
    /// primitive used elsewhere for credential files. Pass
    /// `mode: 0o700` (the only knob this site needs that the
    /// credentials default `0o600` doesn't cover) and the same
    /// race-free guarantees apply: the script is born with the
    /// restrictive mode and the rename is atomic. Replaces ~50
    /// lines of bespoke FD-lifecycle code that mirrored
    /// `RestrictedFile`'s implementation almost line-for-line —
    /// removing the second-implementation drift risk.
    nonisolated private static func writeRelaunchScript(_ contents: String, to scriptURL: URL) throws {
        guard let data = contents.data(using: .utf8) else {
            throw UpdaterError.message(
                "Internal error: relaunch script not encodable as UTF-8."
            )
        }
        do {
            try RestrictedFile.write(data, to: scriptURL, mode: 0o700)
        } catch {
            throw UpdaterError.message(
                "Couldn't create the relaunch helper script: \(error.localizedDescription)"
            )
        }
    }

    nonisolated private static func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cool-tunnel-app-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Q-F#2: returns the path to `~/Library/Logs/cool-tunnel/
    /// relaunch.log` and ensures the parent directory exists.
    /// The bash helper redirects its stderr to this file so
    /// AU-11's `preswap_trap` recovery hint actually reaches a
    /// place the user (or support) can tail. Single fixed path
    /// (not timestamped) so users only ever have one file to
    /// look at; the helper appends rather than truncating, so
    /// successive failed updates leave a chronological audit
    /// trail capped only by manual `truncate(1)`.
    nonisolated private static func makeRelaunchLogPath() throws -> URL {
        let dir = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("cool-tunnel", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        return dir.appendingPathComponent("relaunch.log", isDirectory: false)
    }

    // MARK: - Version + tag parsing

    /// Validates a tag matches `v?N.N.N(.N)?` shape. Defensive
    /// against a future GitHub-side issue that returns garbage.
    nonisolated static func isValidVersionTag(_ tag: String) -> Bool {
        guard !tag.isEmpty, tag.count <= 64 else { return false }
        let pattern = #"^v?\d+(\.\d+){1,3}(-[A-Za-z0-9.]+)?$"#
        return tag.range(of: pattern, options: .regularExpression) != nil
    }

    /// Returns true if `candidate` strictly outranks `base` under
    /// segment-wise numeric compare. Both must already be
    /// canonical (no leading `v`).
    ///
    /// **AU-12 fix:** previously `Int($0) ?? 0` silently coerced
    /// non-numeric segments to 0, which had two failure modes:
    ///   1. A pre-release tag like `1.0.0-rc1` would split into
    ///      `["1","0","0-rc1"]`, the `0-rc1` segment would coerce
    ///      to 0, and the version compared *equal* to `1.0.0`.
    ///   2. Any garbage segment (`"foo"`) became 0 with no
    ///      diagnostic, masking a real upstream/release-process
    ///      bug.
    /// Now: presence of `-` (pre-release marker) or any
    /// non-numeric segment short-circuits to `false` (no upgrade
    /// offered). `/releases/latest` already excludes pre-releases,
    /// so the only legitimate path through this function is
    /// strict numeric segments.
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
    /// Returns nil if the version contains a `-` (pre-release
    /// marker) or any segment fails to parse strictly. AU-12.
    nonisolated private static func parseVersionSegments(_ version: String) -> [Int]? {
        if version.contains("-") { return nil }
        var segments: [Int] = []
        for raw in version.split(separator: ".") {
            guard let value = Int(raw), value >= 0 else { return nil }
            segments.append(value)
        }
        return segments.isEmpty ? nil : segments
    }

    /// Quotes `arg` for safe inclusion in a bash single-quoted
    /// context. Single quotes inside become `'\''`.
    nonisolated private static func shellQuote(_ arg: String) -> String {
        "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Identity constants

    /// **AU-6:** the canonical Cool Tunnel bundle identifier,
    /// hard-coded so `verifyExtractedApp` has an attacker-
    /// independent comparison anchor. Reading
    /// `Bundle.main.bundleIdentifier` would compare against the
    /// running app's plist — which an attacker who ever managed
    /// to substitute the running app could rewrite. The value
    /// here matches `PRODUCT_BUNDLE_IDENTIFIER` in
    /// `COOL-TUNNEL.xcodeproj/project.pbxproj`. If the bundle
    /// identifier ever legitimately changes (a renaming, a
    /// fork), update both in lock-step.
    nonisolated fileprivate static let canonicalBundleID = "space.coolwhite.naive"

    // **R-F#4:** the URL trust boundary (`isTrustedGitHubURL`)
    // and `GitHubRedirectGuard` previously defined here have
    // moved to `SystemIntegration/GitHubTrust.swift` and are
    // now shared with `NaiveUpdater` and `RustCoreUpdater`,
    // which had the same threat model and no protection until
    // v0.1.7.13.
}

// MARK: - Logging

/// Module-level `os.Logger` for the updater. Used to capture
/// detail (failing URLs, version-mismatch values, status codes)
/// that AU-2 / AU-7 / AU-8 deliberately strip from user-facing
/// errors — the support workflow recovers real values via
/// `log show --predicate 'subsystem == "space.coolwhite.cooltunnel"
/// AND category == "AppUpdater"'`.
///
/// **R-F#2:** migrated from `OSLog` + `os_log("%{public}@", ...)`
/// (the legacy macOS 10.12+ API) to `os.Logger` (macOS 11+),
/// matching the convention `CoreClient.swift` already used. Also
/// fixed the subsystem from the orphan
/// `"com.cool-tunnel.app"` to the project-wide
/// `"space.coolwhite.cooltunnel"` so support's `log show`
/// predicates surface every component under one umbrella.
private let appUpdaterLogger = Logger(
    subsystem: "space.coolwhite.cooltunnel",
    category: "AppUpdater"
)
