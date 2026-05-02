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
            _ = try? await run(["-setsocksfirewallproxystate", service, "off"])
            try await run(["-setautoproxyurl", service, pacURL.absoluteString])
            try await run(["-setautoproxystate", service, "on"])
        }
    }

    /// Disables both SOCKS and PAC proxies on every active network service.
    public func disableAll() async throws {
        for service in try await activeServices() {
            _ = try? await run(["-setsocksfirewallproxystate", service, "off"])
            _ = try? await run(["-setautoproxystate", service, "off"])
        }
    }

    // MARK: - Service discovery

    /// Returns names of network services that aren't disabled in the
    /// "Network" preference pane. Excludes the asterisk-prefixed disabled
    /// services and the leading "An asterisk..." legend line.
    public func activeServices() async throws -> [String] {
        let output = try await run(["-listallnetworkservices"])
        return output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .lazy
            .filter { !$0.contains("asterisk") }
            .map(String.init)
            .filter { !$0.hasPrefix("*") && !$0.isEmpty }
    }

    // MARK: - Subprocess plumbing

    @discardableResult
    private func run(_ arguments: [String]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = networkSetupURL
            process.arguments = arguments
            process.standardOutput = stdout
            process.standardError = stderr

            do {
                try process.run()
            } catch {
                throw SystemProxyError.spawnFailed(error)
            }
            process.waitUntilExit()

            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let outString = String(data: outData, encoding: .utf8) ?? ""
            let errString = String(data: errData, encoding: .utf8) ?? ""

            if process.terminationStatus != 0 {
                throw SystemProxyError.nonZeroExit(
                    code: process.terminationStatus,
                    stderr: errString.isEmpty ? outString : errString
                )
            }
            return outString
        }.value
    }
}
