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
    enum State: Sendable, Equatable {
        case idle
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
    private(set) var lastInstalledTag: String?

    private let supportDirectory: URL

    init(supportDirectory: URL) {
        self.supportDirectory = supportDirectory
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

    /// Kicks off the update. Re-entry while a previous run is
    /// in flight is a no-op so the state machine stays monotonic.
    @discardableResult
    func update() async -> URL? {
        switch state {
        case .resolvingRelease, .downloading, .installing:
            return nil
        default:
            break
        }

        do {
            state = .resolvingRelease
            let (tag, downloadURL) = try await Self.resolveLatestAsset()

            state = .downloading(progress: 0.0)
            let tempRoot = try Self.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: tempRoot) }
            let downloaded = try await Self.download(
                url: downloadURL,
                to: tempRoot.appendingPathComponent("cool-tunnel-core")
            )
            state = .downloading(progress: 1.0)

            state = .installing
            // **CONC-F#1 (v0.1.7.15):** `adhocSign` now async.
            try await Self.adhocSign(at: downloaded)
            try Self.atomicallyInstall(from: downloaded, to: installedURL)

            lastInstalledTag = tag
            state = .succeeded(tag: tag, installedPath: installedURL)
            return installedURL
        } catch let UpdaterError.message(reason) {
            state = .failed(message: reason)
            return nil
        } catch {
            state = .failed(message: error.localizedDescription)
            return nil
        }
    }

    func reset() {
        switch state {
        case .resolvingRelease, .downloading, .installing:
            return
        default:
            state = .idle
        }
    }

    // MARK: - Pipeline (off-main)

    /// Returns `(tag, downloadURL)` for the newest cool-tunnel
    /// release that exposes a `cool-tunnel-core-vX.Y.Z(.W)?-universal`
    /// asset. Walks the recent-releases list rather than hitting
    /// `/releases/latest` because pre-releases may be the only
    /// builds for a while.
    private static func resolveLatestAsset() async throws -> (String, URL) {
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
            if let asset = release.assets.first(where: {
                $0.name.hasPrefix("cool-tunnel-core-v") && $0.name.hasSuffix("-universal")
            }) {
                // **R-F#4:** validate the asset URL is on a
                // trusted GitHub-served host before returning.
                // `browser_download_url` is attacker-influenceable
                // through a compromised API response; without
                // this check (or SHA pinning, which RustCore
                // doesn't have yet), a wrong host could substitute
                // the engine binary entirely.
                guard isTrustedGitHubURL(asset.browserDownloadURL) else {
                    throw UpdaterError.message(
                        "GitHub returned an engine asset URL on an unexpected host. Refusing to update."
                    )
                }
                return (release.tagName, asset.browserDownloadURL)
            }
        }
        throw UpdaterError.message(
            "No engine binary in the recent Cool Tunnel releases. The bundled engine still works; Update will retry next time."
        )
    }

    /// Delegates to `GitHubRedirectGuard.download` — the shared
    /// host-validated, redirect-guarded, size-capped download
    /// primitive. Engine binary is ~5 MB so the default 100 MB
    /// cap is generous slack.
    private static func download(url: URL, to destination: URL) async throws -> URL {
        do {
            return try await GitHubRedirectGuard.download(url: url, to: destination)
        } catch let untrusted as UntrustedGitHubHostError {
            rustCoreUpdaterLogger.error(
                "untrusted host: \(untrusted.url.absoluteString, privacy: .public)"
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
