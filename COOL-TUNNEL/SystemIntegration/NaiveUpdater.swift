// SystemIntegration/NaiveUpdater.swift
//
// Downloads the latest upstream NaiveProxy macOS build (arm64 + x64),
// lipo-merges the two slices into one universal Mach-O, ad-hoc signs
// it, and drops it into the user's Application Support directory so
// the orchestrator can adopt it as a custom binary path. Mirrors
// `scripts/fetch_naive.sh` but lives inside the app so the Settings
// "Update naive" button works on an installed `.app` (where the
// bundled `Contents/Resources/naive` is read-only and re-signing it
// would invalidate the app's own signature).
//
// Wire flow:
//
//   1. GET https://api.github.com/repos/klzgrad/naiveproxy/releases
//      → pick newest non-prerelease tag.
//   2. Download both arm64 + x64 .tar.xz assets to a temp dir.
//   3. Extract via `/usr/bin/tar -xJf`.
//   4. lipo -create the two `naive` binaries → universal output.
//   5. codesign --force --sign - (ad-hoc).
//   6. Atomically move into
//      `~/Library/Application Support/COOL-TUNNEL/naive-managed`
//      with mode 0755 (executable for the user).
//
// Concurrency: the updater is `@MainActor` because it publishes
// `state` to SwiftUI; the heavy work happens off-main inside
// `Task.detached` blocks.

import Foundation
import Observation

/// Live state of an in-flight or finished update. `@Observable` so
/// the Settings view re-renders as the updater advances through the
/// pipeline without manual binding plumbing.
@MainActor
@Observable
public final class NaiveUpdater {

    /// What the updater is doing right now.
    public enum State: Sendable, Equatable {
        case idle
        case resolvingTag
        case downloading(progress: Double)  // 0.0 – 1.0
        case extracting
        case merging
        case installing
        /// Finished successfully. `installedPath` is the path the
        /// orchestrator should adopt as `customNaiveBinaryPath` to
        /// pick up the new binary.
        case succeeded(tag: String, installedPath: URL)
        case failed(message: String)
    }

    public private(set) var state: State = .idle
    public private(set) var lastInstalledTag: String?

    private let supportDirectory: URL

    public init(supportDirectory: URL) {
        self.supportDirectory = supportDirectory
    }

    /// Convenience initializer using the standard
    /// `~/Library/Application Support/COOL-TUNNEL` directory.
    public convenience init(paths: AppSupportPaths) {
        self.init(supportDirectory: paths.supportDirectory)
    }

    /// Path the updater writes the merged binary to. Stable across
    /// updates so `customNaiveBinaryPath` keeps pointing at it.
    public var installedURL: URL {
        supportDirectory.appendingPathComponent("naive-managed", isDirectory: false)
    }

    /// Kicks off the update pipeline. Re-running while a previous
    /// update is in flight is a no-op (the previous run's promise
    /// finishes first). Returns the installed URL on success or
    /// nil on any failure — full diagnostic in `state`.
    @discardableResult
    public func update() async -> URL? {
        // Reject a second concurrent update — keep state machine
        // monotonic so the UI never sees overlapping `downloading(0.4)`
        // -> `downloading(0.1)` regressions.
        switch state {
        case .resolvingTag, .downloading, .extracting, .merging, .installing:
            return nil
        default:
            break
        }

        do {
            state = .resolvingTag
            let tag = try await Self.resolveLatestStableTag()
            // Validate the tag before interpolating it into a URL
            // path. GitHub release tags are typically `vN.N.N-N`
            // but the API returns whatever upstream pushed —
            // characters like `..`, spaces, `?`, `#`, `/` would
            // produce a URL that points outside the intended
            // release directory. Reject anything that doesn't
            // match the canonical version-tag shape.
            guard Self.isValidReleaseTag(tag) else {
                throw UpdaterError.message(
                    "GitHub returned an unexpected release tag (\(tag)). Refusing to download — check upstream and try again."
                )
            }

            let tempRoot = try Self.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: tempRoot) }

            // Download both arches in parallel (network-bound, no CPU
            // contention). `try await` on both surfaces whichever
            // fails first.
            state = .downloading(progress: 0.0)
            let arm64URL = try Self.assetURL(tag: tag, arch: .arm64)
            let x64URL = try Self.assetURL(tag: tag, arch: .x64)
            async let arm64Tarball = Self.download(
                url: arm64URL,
                to: tempRoot.appendingPathComponent("arm64.tar.xz")
            )
            async let x64Tarball = Self.download(
                url: x64URL,
                to: tempRoot.appendingPathComponent("x64.tar.xz")
            )
            let arm64Path = try await arm64Tarball
            let x64Path = try await x64Tarball
            state = .downloading(progress: 1.0)

            state = .extracting
            let arm64Bin = try Self.extractNaive(
                from: arm64Path, into: tempRoot.appendingPathComponent("arm64"))
            let x64Bin = try Self.extractNaive(from: x64Path, into: tempRoot.appendingPathComponent("x64"))

            state = .merging
            let merged = tempRoot.appendingPathComponent("naive-universal")
            try Self.lipoCreate(arm64: arm64Bin, x64: x64Bin, output: merged)
            try Self.adhocSign(at: merged)

            state = .installing
            try Self.atomicallyInstall(from: merged, to: installedURL)

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

    /// Resets the visible state back to `.idle`. Called from the
    /// Settings view when the sheet dismisses so a stale failure
    /// banner doesn't follow the user back into the form.
    public func reset() {
        switch state {
        case .resolvingTag, .downloading, .extracting, .merging, .installing:
            return  // Don't clobber an in-flight update.
        default:
            state = .idle
        }
    }

    // MARK: - Pipeline steps (all run off-main)

    private enum Arch { case arm64, x64 }

    /// Whether `tag` matches the canonical NaiveProxy release-tag
    /// shape (`v131.0.6778.85-1`, `v147.0.7727.49-1`, etc.). Used
    /// as a defense-in-depth check before path interpolation —
    /// see [`assetURL`].
    static func isValidReleaseTag(_ tag: String) -> Bool {
        // Allow `v` + 1-4 numeric segments + optional `-N` suffix.
        // NaiveProxy uses Chromium's 4-segment scheme; the upstream
        // build counter is appended as `-1`, `-2`, etc.
        guard !tag.isEmpty, tag.count <= 64 else { return false }
        let pattern = #"^v?\d+(\.\d+){0,3}(-[A-Za-z0-9.]+)?$"#
        return tag.range(of: pattern, options: .regularExpression) != nil
    }

    private static func assetURL(tag: String, arch: Arch) throws -> URL {
        let archToken = arch == .arm64 ? "arm64-arm64" : "x64-x64"
        let asset = "naiveproxy-\(tag)-mac-\(archToken).tar.xz"
        let urlString =
            "https://github.com/klzgrad/naiveproxy/releases/download/\(tag)/\(asset)"
        // Surface as a thrown error rather than `fatalError` so a
        // future maintainer who introduces an interpolation bug
        // (e.g. an unsanitised version string) gets a friendly
        // updater error in the UI instead of a process crash.
        // Mirrors the safe-guard pattern in
        // `resolveLatestStableTag` below.
        guard let url = URL(string: urlString) else {
            throw UpdaterError.message(
                "internal error: constructed invalid release URL: \(urlString)"
            )
        }
        // **R-F#4:** defence-in-depth check that the URL we
        // constructed (or any future upstream-derived URL plumbed
        // through here) is HTTPS and on a GitHub-served host.
        // Today the URL template is hardcoded so this is
        // belt-and-braces; cheap, and aligns with the
        // AppUpdater AU-2 trust boundary.
        guard isTrustedGitHubURL(url) else {
            throw UpdaterError.message(
                "internal error: release URL is not on a trusted GitHub host: \(urlString)"
            )
        }
        return url
    }

    /// Hits the GitHub releases API and picks the highest-priority
    /// stable (non-prerelease) tag. Used instead of `/releases/latest`
    /// because the upstream sometimes flips that endpoint to
    /// pre-release tags.
    private static func resolveLatestStableTag() async throws -> String {
        // Compile-time constant URL — `URL(string:)` returns nil only
        // for malformed input, which a hardcoded API path can never be.
        // Using `URL(static:)`-style guard avoids the bare `!` that
        // the v0.1.5.9 audit flagged as masking future force-unwrap
        // additions during refactoring.
        guard let apiURL = URL(string: "https://api.github.com/repos/klzgrad/naiveproxy/releases?per_page=20")
        else {
            throw UpdaterError.message("internal error: invalid hardcoded GitHub API URL")
        }
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Cool-Tunnel-Updater", forHTTPHeaderField: "User-Agent")

        // **R-F#4 (v0.1.7.13):** the redirect guard from
        // `GitHubTrust.swift` constrains any HTTP redirect this
        // request encounters to trusted GitHub-served hosts.
        // Without it, a CDN takeover or upstream redirect
        // misconfiguration could substitute the response body —
        // and NaiveUpdater has no SHA pinning today (deferred to
        // v0.2.0 per Sw#C4), so the redirect guard is the ONLY
        // line of defence between an attacker and the binary.
        let (data, response) = try await URLSession.shared.data(
            for: request, delegate: GitHubRedirectGuard.shared
        )
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdaterError.message(
                "Couldn't reach GitHub to look up the latest NaiveProxy release. Check your internet connection and try again."
            )
        }

        // GitHub's JSON uses snake_case, Swift wants camelCase for
        // the property — `CodingKeys` does the bridge.
        struct Release: Decodable {
            let tagName: String
            let prerelease: Bool

            enum CodingKeys: String, CodingKey {
                case tagName = "tag_name"
                case prerelease
            }
        }
        let releases = try JSONDecoder().decode([Release].self, from: data)
        guard let stable = releases.first(where: { !$0.prerelease }) ?? releases.first else {
            throw UpdaterError.message("no NaiveProxy releases found upstream")
        }
        return stable.tagName
    }

    /// Streams a URL to disk via `URLSession.download`.
    ///
    /// **Progress reporting is currently indeterminate.** The
    /// `URLSession.shared.download(from:)` async API does not
    /// surface byte-level progress; the caller flips
    /// `state = .downloading(progress: 0.0)` before calling and
    /// jumps straight to `1.0` after. The Settings UI shows a
    /// determinate-looking bar that is in fact a 0%-then-100% step.
    /// A future patch can switch to `URLSessionDownloadDelegate` to
    /// report real progress; deferred to keep the LTSC patch surface
    /// small.
    private static func download(url: URL, to destination: URL) async throws -> URL {
        // **R-F#4:** redirect guard + host check. See the
        // `assetURL` and `resolveLatestStableTag` notes for
        // why this matters even without SHA pinning.
        guard isTrustedGitHubURL(url) else {
            throw UpdaterError.message(
                "Refusing to download from non-GitHub host."
            )
        }
        let request = URLRequest(url: url)
        let (tempURL, response) = try await URLSession.shared.download(
            for: request, delegate: GitHubRedirectGuard.shared
        )
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdaterError.message(
                "Couldn't download \(url.lastPathComponent). Check your internet connection and try Update again."
            )
        }
        // Move into our temp dir so both downloads end up in
        // predictable filenames the rest of the pipeline can find.
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
        return destination
    }

    private static func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cool-tunnel-naive-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Extracts a `.tar.xz` archive into `target` and returns the
    /// path to the inner `naive` binary. The upstream tarballs always
    /// contain a single top-level directory whose contents include
    /// `naive`; we strip the leading component so the binary lands
    /// directly in `target`.
    private static func extractNaive(from archive: URL, into target: URL) throws -> URL {
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try runProcess(
            executable: "/usr/bin/tar",
            arguments: ["-xJf", archive.path, "-C", target.path, "--strip-components=1"]
        )
        let binary = target.appendingPathComponent("naive")
        guard FileManager.default.fileExists(atPath: binary.path) else {
            throw UpdaterError.message(
                "The downloaded NaiveProxy archive looked incomplete. Try Update again — the previous download was probably interrupted."
            )
        }
        return binary
    }

    private static func lipoCreate(arm64: URL, x64: URL, output: URL) throws {
        try runProcess(
            executable: "/usr/bin/lipo",
            arguments: ["-create", arm64.path, x64.path, "-output", output.path]
        )
    }

    private static func adhocSign(at url: URL) throws {
        try runProcess(
            executable: "/usr/bin/codesign",
            arguments: ["--force", "--sign", "-", "--timestamp=none", url.path]
        )
    }

    /// Atomic install: write to `<destination>.new`, then `rename`
    /// over the final path. Avoids leaving a half-copied binary at
    /// the destination if the process is killed mid-copy.
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

    /// Tiny `Process` helper that throws a typed error on non-zero
    /// exit. Captures stdout+stderr for the failure message so the
    /// Settings UI can show *why* a step failed.
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
            throw UpdaterError.message("could not launch \(executable): \(error.localizedDescription)")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: data, encoding: .utf8) ?? ""
            throw UpdaterError.message(
                "\(URL(fileURLWithPath: executable).lastPathComponent) exit \(process.terminationStatus): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
    }
}

/// Internal typed error so each pipeline step can raise a
/// human-readable message that the `update()` catch-all turns into
/// a `.failed(message:)` state.
enum UpdaterError: Error, Sendable {
    case message(String)
}
