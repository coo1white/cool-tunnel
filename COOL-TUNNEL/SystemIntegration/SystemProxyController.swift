// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
// SystemIntegration/SystemProxyController.swift
//
// Thin async wrapper over `/usr/sbin/networksetup`. Used to enable / disable
// the system SOCKS proxy and the auto-proxy URL pointing at our PAC file.

import Foundation

/// Errors produced while invoking `networksetup`.
public enum SystemProxyError: Error, Sendable {
    /// `networksetup` could not be spawned.
    case spawnFailed(any Error)
    /// `networksetup` exited with a non-zero status.
    case nonZeroExit(code: Int32, stderr: String)
}

/// Async facade over the macOS `networksetup` command-line tool.
///
/// The controller is a value type with no mutable state; each method spawns
/// `networksetup` synchronously and returns its captured stdout.
public struct SystemProxyController: Sendable {

    private let networkSetupURL: URL

    public init(networkSetupURL: URL = URL(fileURLWithPath: "/usr/sbin/networksetup")) {
        self.networkSetupURL = networkSetupURL
    }

    // MARK: - High-level operations

    /// Configures every active network service to send **all** TCP traffic
    /// through `127.0.0.1:port` via macOS's SOCKS proxy setting.
    ///
    /// Also clears any previously configured PAC URL so the two modes never
    /// stack on top of each other.
    public func enableGlobalSOCKS(port: UInt16) async throws {
        for service in try await activeServices() {
            // Clear PAC first so smart-mode leftovers don't override.
            // try-ok: clear stale PAC; mode hop is the real intent
            _ = try? await run(["-setautoproxystate", service, "off"])
            try await run(["-setsocksfirewallproxy", service, "127.0.0.1", String(port)])
            try await run(["-setsocksfirewallproxystate", service, "on"])
        }
    }

    /// Configures every active network service to consult `pacURL` for
    /// per-domain proxy decisions (smart routing: domestic domains go
    /// DIRECT, everything else through SOCKS).
    ///
    /// Also clears any previously configured global SOCKS proxy so the two
    /// modes never stack on top of each other.
    public func enableSmartPAC(pacURL: URL) async throws {
        for service in try await activeServices() {
            // Clear global SOCKS first so global-mode leftovers don't override.
            // try-ok: clear stale SOCKS; mode hop is the real intent
            _ = try? await run(["-setsocksfirewallproxystate", service, "off"])
            try await run(["-setautoproxyurl", service, pacURL.absoluteString])
            try await run(["-setautoproxystate", service, "on"])
        }
    }

    /// Disables both SOCKS and PAC proxies on every active network service.
    public func disableAll() async throws {
        for service in try await activeServices() {
            // try-ok: best-effort revert; service may already be off
            _ = try? await run(["-setsocksfirewallproxystate", service, "off"])
            // try-ok: best-effort revert; service may already be off
            _ = try? await run(["-setautoproxystate", service, "off"])
        }
    }

    // MARK: - Service discovery

    /// Returns names of network services that aren't disabled in the
    /// "Network" preference pane.
    ///
    /// **v0.1.7.19 (localization fix):** previously filtered the
    /// legend line via `.contains("asterisk")` — broken on
    /// non-English macOS where the legend is localized
    /// ("Un servicio desactivado…", "Un service désactivé…",
    /// etc.). `networksetup` always emits exactly one legend
    /// line as the first line, so `dropFirst(1)` is the
    /// stable, locale-independent filter.
    public func activeServices() async throws -> [String] {
        let output = try await run(["-listallnetworkservices"])
        return
            output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .dropFirst(1)
            .map(String.init)
            .filter { !$0.hasPrefix("*") && !$0.isEmpty }
    }

    // MARK: - Subprocess plumbing

    /// **Subproc-F#11b (v0.1.7.19):** routes through the shared
    /// `Subprocess.run` helper — concurrent pipe drain + 30s
    /// timeout escalation + sanitized env (PATH allowlist,
    /// drop DYLD_*/OBJC_*, LANG=C). Previously this used the
    /// legacy `process.waitUntilExit()` + `readDataToEndOfFile`
    /// pattern that Subprocess.swift was built to replace —
    /// exactly the pipe-deadlock scenario for `networksetup
    /// -listallnetworkservices` on a Mac with many services.
    @discardableResult
    private func run(_ arguments: [String]) async throws -> String {
        let result: SubprocessResult
        do {
            result = try await Subprocess.run(
                executable: networkSetupURL,
                arguments: arguments,
                timeout: 30
            )
        } catch SubprocessError.launchFailed(let message) {
            throw SystemProxyError.spawnFailed(
                NSError(
                    domain: "SystemProxyError",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: message]
                )
            )
        } catch {
            throw SystemProxyError.spawnFailed(error)
        }
        if result.timedOut {
            throw SystemProxyError.nonZeroExit(
                code: -1,
                stderr: "networksetup did not finish within 30s"
            )
        }
        if !result.success {
            throw SystemProxyError.nonZeroExit(
                code: result.exitCode,
                stderr: result.stderr.isEmpty ? result.stdout : result.stderr
            )
        }
        return result.stdout
    }
}
