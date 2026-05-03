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

/// Live state of an in-flight or finished Rust core update.
/// `@Observable` so the Settings view re-renders as the updater
/// advances through the pipeline without manual binding plumbing.
@MainActor
@Observable
public final class RustCoreUpdater {

    /// What the updater is doing right now.
    public enum State: Sendable, Equatable {
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

    public private(set) var state: State = .idle
    public private(set) var lastInstalledTag: String?

    private let supportDirectory: URL

    public init(supportDirectory: URL) {
        self.supportDirectory = supportDirectory
    }

    public convenience init(paths: AppSupportPaths) {
        self.init(supportDirectory: paths.supportDirectory)
    }

    /// Stable target path. Used by Settings as the value to write
    /// into `customRustCorePath` after a successful update.
    public var installedURL: URL {
        supportDirectory.appendingPathComponent(
            "cool-tunnel-core-managed",
            isDirectory: false
        )
    }

    /// Kicks off the update. Re-entry while a previous run is
    /// in flight is a no-op so the state machine stays monotonic.
    @discardableResult
    public func update() async -> URL? {
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
            try Self.adhocSign(at: downloaded)
            try Self.atomicallyInstall(from: downloaded, to: installedURL)

            lastInstalledTag = tag
            state = .succeeded(tag: tag, installedPath: installedURL)
            return installedURL
        } catch let RustUpdaterError.message(reason) {
            state = .failed(message: reason)
            return nil
        } catch {
            state = .failed(message: error.localizedDescription)
            return nil
        }
    }

    public func reset() {
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
        let apiURL = URL(string: "https://api.github.com/repos/coo1white/cool-tunnel/releases?per_page=20")!
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Cool-Tunnel-Updater", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RustUpdaterError.message("GitHub API returned an unexpected response")
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
                return (release.tagName, asset.browserDownloadURL)
            }
        }
        throw RustUpdaterError.message("no cool-tunnel-core asset found in recent releases")
    }

    private static func download(url: URL, to destination: URL) async throws -> URL {
        let (tempURL, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RustUpdaterError.message("download failed for \(url.lastPathComponent)")
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
        return destination
    }

    private static func adhocSign(at url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
        try runProcess(
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

    private static func runProcess(executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw RustUpdaterError.message(
                "could not launch \(executable): \(error.localizedDescription)"
            )
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: data, encoding: .utf8) ?? ""
            throw RustUpdaterError.message(
                "\(URL(fileURLWithPath: executable).lastPathComponent) exit \(process.terminationStatus): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
    }
}

/// Internal typed error so each pipeline step can raise a
/// human-readable message that the `update()` catch-all turns
/// into a `.failed(message:)` state. Same shape as
/// `NaiveUpdater`'s `UpdaterError` but namespaced so the two
/// cannot collide.
enum RustUpdaterError: Error, Sendable {
    case message(String)
}
