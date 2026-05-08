// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
// SystemIntegration/HostArchitecture.swift
//
// Tells the rest of the app which CPU it is running on. The naive binary
// must contain a Mach-O slice for this architecture or the proxy will
// fail with "Bad CPU type in executable" at spawn time. Knowing the host
// arch up front lets the resolver and Settings UI surface that mismatch
// before the user hits the "Start" button.

import Darwin
import Foundation

/// CPU architecture of the running Mac.
public enum HostArchitecture: String, Sendable, Equatable, CaseIterable {
    /// Apple Silicon (M-series). Mach-O slice name: `arm64`.
    case appleSilicon = "arm64"
    /// Intel x86_64. Mach-O slice name: `x86_64`.
    case intel = "x86_64"
    /// Sysctl returned a string we did not recognise. Treated as a hard
    /// failure by the resolver — better to surface a clear error than to
    /// guess and crash later.
    case unknown = "unknown"

    /// Human-readable name for Settings and error messages.
    public var displayName: String {
        switch self {
        case .appleSilicon: "Apple Silicon"
        case .intel: "Intel"
        case .unknown: "Unknown"
        }
    }

    /// Mach-O slice identifier matching `lipo -info` output for this arch.
    public var machOArchName: String { rawValue }

    /// Detects the host architecture by reading `hw.machine` via sysctl.
    /// Cached after the first call — the answer cannot change without a
    /// reboot, so re-querying every settings open would be wasteful.
    public static let current: HostArchitecture = detect()

    private static func detect() -> HostArchitecture {
        var size: Int = 0
        // First call sizes the buffer; second call fills it. Standard
        // sysctlbyname two-step pattern.
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else {
            return .unknown
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &buffer, &size, nil, 0) == 0 else {
            return .unknown
        }
        // sysctl returns a NUL-terminated C string; trim the terminator
        // before handing the bytes to the UTF-8 decoder so the trailing
        // \0 does not survive into the comparison below.
        let trimmed = buffer.prefix(while: { $0 != 0 })
        let raw = String(decoding: trimmed, as: UTF8.self)
        switch raw {
        case "arm64", "arm64e": return .appleSilicon
        case "x86_64": return .intel
        default: return .unknown
        }
    }
}
