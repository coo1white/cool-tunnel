// SystemIntegration/FirewallProbe.swift
//
// Reads the macOS Application Firewall global state. Surfaced in the UI
// when the user is troubleshooting a connectivity problem.

import Foundation

/// Reports the current state of the Application Firewall.
public enum FirewallState: Sendable, Equatable {
    case disabled
    case enabled
    case unknown

    public var description: String {
        switch self {
        case .disabled: "Firewall: off"
        case .enabled: "Firewall: on (may block connections)"
        case .unknown: "Firewall: status unknown"
        }
    }
}

public struct FirewallProbe: Sendable {

    private let socketFilterURL: URL

    public init(
        socketFilterURL: URL = URL(
            fileURLWithPath: "/usr/libexec/ApplicationFirewall/socketfilterfw"
        )
    ) {
        self.socketFilterURL = socketFilterURL
    }

    /// Reads `--getglobalstate`. Returns [`FirewallState.unknown`] when the
    /// process can't be spawned or its output is unrecognised.
    public func currentState() async -> FirewallState {
        await Task.detached(priority: .utility) {
            let process = Process()
            let stdout = Pipe()
            process.executableURL = socketFilterURL
            process.arguments = ["--getglobalstate"]
            process.standardOutput = stdout
            process.standardError = Pipe()
            do {
                try process.run()
            } catch {
                return .unknown
            }
            process.waitUntilExit()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.lowercased() ?? ""
            if output.contains("disabled") {
                return .disabled
            }
            if output.contains("enabled") {
                return .enabled
            }
            return .unknown
        }.value
    }
}
