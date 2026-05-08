// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
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
        // Wrapped in `Subprocess.run` so a wedged
        // `socketfilterfw` (which can happen on managed Macs with
        // certain MDM extensions) cannot freeze app boot. The
        // 5-second timeout is well above the typical sub-100 ms
        // response and short enough to keep the launch sequence
        // responsive.
        let result: SubprocessResult
        do {
            result = try await Subprocess.run(
                executable: socketFilterURL,
                arguments: ["--getglobalstate"],
                timeout: 5
            )
        } catch {
            return .unknown
        }
        let output = result.stdout.lowercased()
        if output.contains("disabled") {
            return .disabled
        }
        if output.contains("enabled") {
            return .enabled
        }
        return .unknown
    }
}
