// SystemIntegration/AppUpdater.swift
//
// In-app self-updater for the Cool Tunnel `.app`. SHA-256
// manifest-pinned: every release ships a
// `Cool-tunnel-vX.Y.Z.sha256` alongside the .zip; we download
// both, verify the .zip's hash against the manifest line, and
// refuse to install on any mismatch.
//
// Pipeline:
//   1. GET /releases/latest; no-op if not newer than the running
//      `CFBundleShortVersionString`.
//   2. Download the .zip + .sha256 asset (in parallel).
//   3. Stream-hash the .zip; cross-reference the manifest line.
//   4. Extract via `ditto -x -k` through `Subprocess.run`
//      (concurrent pipe drain, timeout escalation, sanitized env).
//   5. Walk the extraction tree — reject hard links, symlinks
//      that escape the bundle root, more than one .app, anything
//      that isn't a real bundle directory.
//   6. Verify the extracted bundle's `CFBundleIdentifier`
//      matches `canonicalBundleID` (a hard-coded constant — NOT
//      `Bundle.main.bundleIdentifier`, which is attacker-
//      controllable if the running app was ever substituted),
//      its `CFBundleShortVersionString` matches the release tag,
//      and `CodeSignVerifier` accepts the bundle.
//   7. Refuse if the running app is on a read-only volume, in a
//      non-writable folder, or has the bundle itself locked.
//   8. Refuse if multiple real installs exist (filtered to skip
//      Xcode build artifacts; see `isPlausibleUserInstall`).
//   9. Pre-flight free disk space on tempRoot.
//  10. Write the bash relaunch helper into tempRoot atomically
//      via `RestrictedFile.write(mode: 0o700)`, spawn detached.
//  11. `NSApp.terminate(nil)`; the helper waits for parent PID
//      exit, atomic-renames a STAGED bundle into place with
//      rollback on any error, then `open`s the new bundle.
//
// Posture:
// - We do NOT request admin escalation. `/Applications` is
//   admin-group writable by default; users drag the .app there
//   once, after which updates need no sudo prompt.
// - The relaunch helper writes ONLY at the existing bundle URL
//   and only after every verification step has passed.
// - SHA pinning (Sw#C4) is shipped here for the .app itself; the
//   matching pin for the bundled `naive` is targeted for v0.1.8
//   and tracked in SECURITY.md's "does NOT protect against".
//
// Per-fix audit-tag breadcrumbs (`AU-1`..`AU-15`, `R-F#1`..,
// `Q-F#1`.., `Edge-F#1/F#11`, etc.) used to live here in a
// release-history block; that information now lives in
// CHANGELOG.md where git blame can find it. Inline comments
// in this file describe the *invariant* a piece of code
// upholds, not the cycle in which it was added.

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

    // **ARCH-F#1 (v0.1.7.15):** the per-class `UpdaterError`
    // moved to `SystemIntegration/UpdaterError.swift` and is
    // now shared with `NaiveUpdater` and `RustCoreUpdater`.

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
        // **Edge-F#11 (v0.1.7.16):** detect multiple installed
        // copies of Cool Tunnel BEFORE the helper writes anything.
        // If the user has /Applications/Cool Tunnel.app AND
        // ~/Applications/Cool Tunnel.app (or any other copy with
        // matching bundle ID), the relaunch helper would update
        // whichever was launched but LaunchServices' identifier-
        // resolution may pick a different one on next double-
        // click — leaving the user with a "successful" update
        // that doesn't appear to have changed anything. Better
        // to refuse and tell them which copies exist.
        do {
            try await Self.refuseIfMultipleInstalls()
        } catch let UpdaterError.message(reason) {
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
            // **v2.0.7 (relaunch-stuck-fix):** belt-and-braces
            // hard-exit fallback. v2.0.6 users reported the UI
            // sticking on "Relaunching… The app will close in a
            // moment." indefinitely. The clean path is
            // `NSApp.terminate(nil)` →
            // `applicationShouldTerminate` returns
            // `.terminateLater` → orchestrator shutdown Task
            // calls `NSApp.reply(toApplicationShouldTerminate:
            // true)`, with a 5 s watchdog Task as backup. In
            // some scenarios (e.g. an in-flight URLSession
            // download holding the run loop, or a SwiftUI
            // window-close animation racing the reply) neither
            // Task fires soon enough and the process never
            // exits — the relaunch helper waits on our PID
            // forever, and the user sees the spinner stuck.
            //
            // We schedule a detached Task that calls
            // `Darwin.exit(0)` 8 seconds from now,
            // unconditionally. If the clean shutdown path wins
            // first we never reach this; otherwise the relaunch
            // helper sees our PID disappear and proceeds. Any
            // system-proxy state we'd normally clean up in
            // `orchestrator.shutdown()` is recovered by the
            // `recoverFromCrashIfNeeded` sweep on the next
            // launch — the same path that handles a real crash.
            //
            // 8 s is comfortably longer than the 5 s
            // applicationShouldTerminate watchdog, so the clean
            // path still has every chance to win.
            Task.detached {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                Darwin.exit(0)
            }
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
        // **SEC-F#11 (v0.1.7.15):** discourage edge caching /
        // 0-RTT replay of the metadata response. A network
        // attacker (Threat T1) replaying a captured
        // pre-security-fix response could otherwise downgrade
        // the offered version. The HTTPS body is integrity-
        // protected against tampering, but is replayable; this
        // header asks GitHub's edge to serve fresh.
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
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
        // **Edge-F#1 (v0.1.7.16):** disk-space pre-flight on
        // tempRoot. Without this, a 100 MB .zip download could
        // succeed onto a near-full volume, only to fail at the
        // ditto-extract step with an attacker-influenceable
        // "No space left on device" stderr that AppUpdater used
        // to surface verbatim. Refuse early with an actionable
        // message. 300 MB ≈ 100 MB .zip + ~50 MB extracted
        // bundle + slack for the relaunch helper's STAGED copy.
        try requireFreeSpace(at: tempRoot, atLeast: 300 * 1024 * 1024)

        let zipURL = tempRoot.appendingPathComponent(release.zipURL.lastPathComponent)
        let shaURL = tempRoot.appendingPathComponent(release.shaManifestURL.lastPathComponent)

        // **E-F#1:** the .zip and .sha256 fetches are independent
        // (the manifest doesn't gate the .zip request — both URLs
        // come from the already-validated GitHub release JSON).
        // Previously they ran serially, costing ~12 MB + ~250 B
        // back-to-back ≈ same wall-time as the .zip alone × 2.
        // `async let` joins them in parallel; the manifest fetch
        // typically completes during the .zip's TLS handshake.
        async let zipDownload: Void = download(release.zipURL, to: zipURL)
        async let shaDownload: Void = download(release.shaManifestURL, to: shaURL)
        _ = try await zipDownload
        _ = try await shaDownload
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
            actualSha = try SHAVerifier.sha256(of: zipURL)
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
        // entry like `Cool Tunnel.app/Contents/Resources/foo ->
        // /Users/<you>/.ssh/config` would, after extraction,
        // leave a side-channel symlink Cool Tunnel might later
        // follow. Bundle-id + version + codesign verification
        // protects the .app itself; the symlink walk closes
        // the side-channel.
        try refuseExtractionEscapingSymlinks(in: destination)
    }

    /// Cap on how many filesystem entries the extraction walker
    /// will inspect per archive. Used to bound attacker-controlled
    /// work multipliers (E-F#8 symlink count, SEC-F#8 hard-link
    /// detection). 1024 is far above any legitimate macOS .app
    /// bundle (counts in the low double digits).
    nonisolated private static let maxExtractionSymlinks: Int = 1024

    /// Walks `directory` recursively. If any entry is a symbolic
    /// link whose realpath escapes `directory` OR a regular file
    /// with `st_nlink > 1` (hard-linked to something outside
    /// the bundle, possibly in the user's home), throws. AU-5
    /// (path-component ancestor check) + E-F#8 (entry-count cap)
    /// + R-F#7 (realpath helper) + **SEC-F#8 (v0.1.7.15)** hard
    /// link rejection.
    ///
    /// **SEC-F#8 rationale:** prior to this, the walker only
    /// inspected entries with `isSymbolicLink == true`. PKZip's
    /// `ditto`-extension preserves hard links — a malicious zip
    /// can plant an entry like
    /// `Cool Tunnel.app/Contents/Resources/foo` as a hard link
    /// to `/etc/passwd` or to a user file (e.g. `~/.ssh/config`).
    /// Post-extraction the bundle reads attacker-chosen bytes
    /// (or, more dangerously, writes to the linked file when
    /// the running app updates a resource). Bundle-id + version
    /// + codesign verification protect the .app proper but the
    /// linked-to file is in the side-channel. `nlinks > 1` for
    /// any regular file in a freshly-extracted bundle is
    /// unambiguously suspicious.
    nonisolated private static func refuseExtractionEscapingSymlinks(in directory: URL) throws {
        // Resolve the container to its canonical absolute path
        // so the ancestor check is robust against any symlinks
        // in the tempdir hierarchy (e.g. /var → /private/var on
        // macOS).
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
            // **SEC-F#8 (v0.1.7.15):** hard-link detection.
            // For regular files (not symlinks, not directories),
            // check `st_nlink` via `attributesOfItem`. Anything
            // > 1 means the inode is shared with another path
            // somewhere on disk — possibly outside the
            // extraction. A legitimate freshly-extracted bundle
            // will have `nlinks == 1` for every regular file.
            if resources.isRegularFile == true && !isSymlink {
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
            guard let targetComponents = canonicalPathComponents(of: item.path) else {
                throw UpdaterError.message(
                    "Update archive contains a broken symbolic link; refusing to install."
                )
            }
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

    /// **R-F#7:** shared realpath wrapper. Wraps the
    /// `realpath(3)` syscall + `String(cString:)` conversion +
    /// `free` + `URL.pathComponents` extraction in one place;
    /// used for both the container path (once per call) and
    /// each symlink target (per-entry, capped by
    /// `maxExtractionSymlinks`).
    ///
    /// **Q-F#5 (v0.1.7.14):** returns `nil` rather than
    /// throwing with a caller-supplied `errorMessage:`. The
    /// helper's job is "canonicalise this path"; the user-
    /// facing error wording belongs at the call site so the
    /// two failure modes (container couldn't be canonicalised /
    /// symlink target couldn't be canonicalised) can carry
    /// distinct messages without parameterising this primitive.
    nonisolated private static func canonicalPathComponents(of path: String) -> [String]? {
        guard let cStr = realpath(path, nil) else { return nil }
        defer { free(cStr) }
        return URL(fileURLWithPath: String(cString: cStr)).pathComponents
    }

    /// Walks the extraction directory looking for a single .app
    /// bundle. Refuses if zero or more than one is present, or
    /// if the candidate isn't a real bundle directory (AU-14).
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
        // AU-9 part 2 (v2.0.5 rework):
        //
        // History:
        //   - Pre-2.0.3 used `URLResourceKey.isWritableKey` →
        //     too coarse, falsed on App-Management TCC etc.
        //   - 2.0.3 split: `lstat` for chflags + `Darwin.access(W_OK)`
        //     for everything else. Better diagnostic for the
        //     Locked-checkbox case, but `access(W_OK)` was STILL
        //     over-restrictive on macOS 14+: even with the
        //     Cool Tunnel toggle ON in System Settings → Privacy
        //     & Security → App Management, `access(W_OK)` can
        //     keep returning false (TCC permission grants don't
        //     consistently propagate to access(2) syscalls in
        //     the running process until restart). The user
        //     toggled the permission, restarted, retried —
        //     same false-positive error, no path forward.
        //
        // 2.0.5 posture: pre-flight only the conditions we can
        // prove block the install — chflags-immutable and
        // root-owned-bundle-via-pkg-installer. Anything else
        // (ACL inheritance, App Management TCC residue,
        // exotic mode bits) is now trusted to surface from the
        // relaunch helper's actual `mv`/`ditto` call, which
        // logs to `~/Library/Logs/cool-tunnel-relaunch.log`.
        // The pre-flight stops being a barrier for users whose
        // bundle is functionally writable but happens to fail
        // an over-strict `access` heuristic.
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
            // Root-owned bundle (`.pkg` installer puts files in
            // /Applications under root:wheel). The user can read
            // and execute the app, but can't write to it without
            // admin elevation — which the in-app updater can't
            // request without a privileged helper tool.
            let myEUID = geteuid()
            if st.st_uid != myEUID && st.st_uid == 0 {
                appUpdaterLogger.info(
                    "bundle is root-owned (likely .pkg-installed): \(appURL.path, privacy: .public)"
                )
                throw UpdaterError.message(
                    "Cool Tunnel was installed via the .pkg installer, so its bundle is owned by root. The in-app updater can't get past that without admin auth. To self-update from here on:\n\n  1. Quit Cool Tunnel.\n  2. Drag /Applications/Cool Tunnel.app to the Trash (you'll be asked for admin password).\n  3. Reinstall by dragging Cool Tunnel from the .dmg or .zip into /Applications.\n\nFuture updates from .dmg/.zip installations will Just Work."
                )
            }
            // Bundle owned by another non-root user. Rare but
            // happens after a user-rename or unusual transfer.
            if st.st_uid != myEUID {
                appUpdaterLogger.info(
                    "bundle owned by uid \(st.st_uid, privacy: .public), running as \(myEUID, privacy: .public)"
                )
                throw UpdaterError.message(
                    "Cool Tunnel's bundle is owned by another user (UID \(st.st_uid)). The in-app updater can only modify files owned by the user running the app. Either change the bundle's ownership or reinstall as the current user."
                )
            }
        }
        // No `access(W_OK)` pre-flight here — see the long
        // comment above. The relaunch helper's `mv`/`ditto`
        // surface real errors (and log them) for any residual
        // permission case the cheap pre-flight can't classify.
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
            #
            # **Q-F#1 (v0.1.7.14):** dropped the bash-side
            # `mkdir -p "$(dirname "$LOG")"` that lived here. The
            # Swift `makeRelaunchLogPath()` already creates the
            # directory before spawning this script (so a bash-
            # side mkdir was duplicate work) AND its failure path
            # was silent: bash with `set -eu` would abort on
            # mkdir failure, but stderr was still pointing at the
            # parent's `task.standardError = nil` (a closed
            # pipe), so the diagnostic vanished — defeating the
            # whole point of Q-F#2. The Swift side now owns the
            # directory creation; an exec failure here will still
            # be silent, but it's a strict subset of "the dir
            # exists and Foundation's `createDirectory` succeeded
            # but bash can't open the file" — vanishingly rare,
            # and no worse than pre-Q-F#2 behaviour.
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
            #    ("/Applications/Cool Tunnel.app") the `-a` form
            #    treats "Cool" as the app name and "tunnel.app"
            #    as a document, misfiring the relaunch. The
            #    bareword form opens the bundle directly.
            open "$OLD_APP"
            """

        // Helper script lives in tempRoot (already restrictive
        // perms; cleaned up by the script's own EXIT trap). The
        // 0o700 mode is set atomically at file creation —
        // `RestrictedFile.write`'s `O_CREAT|O_EXCL`-then-fsync-
        // then-rename closes the post-write/pre-chmod race the
        // older /tmp + chmod-after pattern had.
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

        // Spawn detached — the parent is about to NSApp.terminate.
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

    /// **Edge-F#11 (v0.1.7.16) + v0.1.7.20 false-positive fix:**
    /// uses Spotlight (`mdfind`) to locate every `.app` whose
    /// bundle identifier matches the canonical ID. The failure
    /// mode this check defends against: the user has two real
    /// installs (e.g. `/Applications` + `~/Applications`), the
    /// helper updates one, LaunchServices launches the other
    /// next time — user thinks the update silently failed.
    ///
    /// **v0.1.7.20:** filter out paths that are clearly NOT
    /// user installs:
    ///   - `~/Library/Developer/Xcode/DerivedData/...` —
    ///     Xcode rebuild caches; LaunchServices won't pick
    ///     these as the canonical install.
    ///   - Any path containing `/DerivedData/` (catches
    ///     project-local DerivedData configs).
    ///   - Any path containing `/Build/Products/` (Xcode
    ///     build products under non-default DerivedData).
    /// Without these filters, ANY developer who has Cool
    /// Tunnel checked out and has run `xcodebuild` even once
    /// false-positives this check — the v0.1.7.16 cycle
    /// shipped with this gap. The error message also lists
    /// the surviving paths so users (and support) know
    /// exactly which copies are still considered installs.
    nonisolated private static func refuseIfMultipleInstalls() async throws {
        let result: SubprocessResult
        do {
            result = try await Subprocess.run(
                executable: URL(fileURLWithPath: "/usr/bin/mdfind"),
                arguments: [
                    "kMDItemCFBundleIdentifier == \"\(canonicalBundleID)\"",
                ],
                timeout: 10
            )
        } catch {
            // mdfind launch failure isn't fatal — Spotlight may
            // be disabled or indexing. Log and continue.
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
        // **v0.1.7.20:** filter Xcode build artifacts before
        // counting. Spotlight indexes everything; for a
        // developer the index includes 5+ DerivedData entries
        // by default, none of which are real installs.
        let paths = result.stdout
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }
            .filter { Self.isPlausibleUserInstall($0) }
        if paths.count > 1 {
            appUpdaterLogger.error(
                "multiple real installs detected: \(paths.joined(separator: ", "), privacy: .public)"
            )
            // List the actual paths so the user knows where
            // to look — without this, the v0.1.7.16 message
            // ("move all but one to the Trash") leaves users
            // hunting for installs in Finder by hand.
            let pathList = paths
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

    /// **v0.1.7.20:** filters Spotlight `mdfind` hits to plausible
    /// user installs only. Excludes Xcode build artifacts that
    /// LaunchServices ignores when resolving a bundle ID:
    ///
    ///   - `/DerivedData/` — anywhere in the path
    ///   - `/Build/Products/` — Xcode's standard build-output dir
    ///   - `/Library/Developer/Xcode/` — global Xcode caches
    ///   - Project-local `build/` directories — `xcodebuild
    ///     -derivedDataPath` writes here when run without a
    ///     workspace
    ///
    /// A "real" install is one of: `/Applications/...`,
    /// `~/Applications/...`, or anywhere outside the patterns
    /// above. False positives here are far worse than false
    /// negatives: a missed real install only re-fires this
    /// check the next time the user clicks Update; a
    /// false-positive blocks every update for every developer.
    nonisolated fileprivate static func isPlausibleUserInstall(_ path: String) -> Bool {
        let xcodeBuildMarkers = [
            "/DerivedData/",
            "/Build/Products/",
            "/Library/Developer/Xcode/",
        ]
        for marker in xcodeBuildMarkers where path.contains(marker) {
            return false
        }
        // Project-local `build/` from a `xcodebuild
        // -derivedDataPath build` invocation. Match
        // `*/build/DerivedData/*` and `*/build/Build/Products/*`
        // explicitly — a path like `/Applications/build-tools/X.app`
        // (legitimate app named with "build") is still kept.
        if path.contains("/build/DerivedData/")
            || path.contains("/build/Build/Products/")
        {
            return false
        }
        return true
    }

    /// **Edge-F#1 (v0.1.7.16):** asserts that the volume
    /// containing `url` has at least `bytes` available for
    /// "important usage" — the URL resource key macOS exposes
    /// for pre-flight checks. Throws an `UpdaterError` with a
    /// recovery hint if the volume is too full. Cheap (a single
    /// `resourceValues` call on a directory URL) so it can run
    /// per-pipeline.
    nonisolated private static func requireFreeSpace(at url: URL, atLeast bytes: Int64) throws {
        let values = try url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
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

    /// Q-F#2: returns the path to `~/Library/Logs/cool-tunnel/
    /// relaunch.log` and ensures the parent directory exists.
    /// The bash helper redirects its stderr to this file so
    /// AU-11's `preswap_trap` recovery hint actually reaches a
    /// place the user (or support) can tail. Single fixed path
    /// (not timestamped) so users only ever have one file to
    /// look at; the helper appends rather than truncating, so
    /// successive failed updates leave a chronological audit
    /// trail capped only by manual `truncate(1)`.
    ///
    /// **Q-F#2 (v0.1.7.14):** replaced the prior `.first!`
    /// force-unwrap with a throwing guard, matching the
    /// project's documented avoid-bare-! convention from the
    /// v0.1.5.9 audit (see `NaiveUpdater.resolveLatestStableTag`
    /// for the same pattern on a hardcoded URL).
    nonisolated private static func makeRelaunchLogPath() throws -> URL {
        guard let library = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)
            .first
        else {
            throw UpdaterError.message(
                "Couldn't locate user Library directory."
            )
        }
        let dir = library
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("cool-tunnel", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let logURL = dir.appendingPathComponent("relaunch.log", isDirectory: false)
        // **SEC-F#7 (v0.1.7.15):** defend against a pre-planted
        // symlink. An attacker with prior file-write access in
        // the user's home (Threat T4) could pre-create
        // `relaunch.log` as a symlink pointing somewhere
        // unwritable (`/dev/full`, a root-owned path). The
        // bash helper's `exec 2>>"$LOG"` would silently fail
        // (with `set -eu` aborting before producing any
        // diagnostic), defeating the whole point of Q-F#2.
        // If the path exists and is anything other than a
        // regular file, unlink it so bash creates a fresh one.
        let resources = try? logURL.resourceValues(forKeys: [
            .isSymbolicLinkKey, .isRegularFileKey,
        ])
        if let r = resources,
            r.isSymbolicLink == true || r.isRegularFile != true
        {
            appUpdaterLogger.info(
                "removing non-regular relaunch.log at \(logURL.path, privacy: .public)"
            )
            try? FileManager.default.removeItem(at: logURL)
        }
        return logURL
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
/// errors. Recovered via
/// `log show --predicate 'subsystem == "space.coolwhite.cooltunnel"
/// AND category == "AppUpdater"'`.
///
/// **R-F#1 (v0.1.7.14):** routed through `Logger.cooltunnel(_:)`
/// so the project-wide subsystem string lives in one place.
private let appUpdaterLogger = Logger.cooltunnel("AppUpdater")
