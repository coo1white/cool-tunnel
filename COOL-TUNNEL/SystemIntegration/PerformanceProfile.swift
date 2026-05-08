// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
// SystemIntegration/PerformanceProfile.swift
//
// Single place that decides "is this Mac fast enough for the rich
// version of the UI, or should we tone things down?". Read once at
// app launch from the cached `HostMachine`, consulted everywhere
// that has an animation density / refresh budget / memory cap to
// pick.
//
// We deliberately don't expose a user-facing toggle — the right
// tier follows from the hardware, and nobody wants a "graphics
// quality" preference in a proxy app's Settings sheet.
//
// Three tiers, picked from the cached host snapshot:
//
//   .full     — Apple Silicon, 8 cores or more. Every effect on,
//               every animation at full spring response.
//   .standard — Apple Silicon with fewer cores, OR Intel with 8+
//               cores. Slightly shorter animations, same effects.
//   .light    — Intel with < 8 physical cores, or any host where
//               sysctl returned junk. Drops the heavier symbol
//               effects (`.pulse(.repeating)` on the status dot
//               in particular) and uses a smaller log buffer to
//               keep the SwiftUI diff cheap.

import Foundation

/// Hardware-derived performance tier. Picked once at launch.
public enum PerformanceProfile: Sendable, Equatable {
    case full
    case standard
    case light

    /// Cached pick from the live host. Never re-evaluated — the
    /// hardware can't change without a reboot.
    public static let current: PerformanceProfile = pick(from: .current)

    /// Animation duration multiplier — bigger means slower. Used as
    /// a knob inside `.animation(.spring(response: base * factor))`
    /// so each call site picks a sensible base and lets the profile
    /// scale it for the host.
    public var animationScale: Double {
        switch self {
        case .full: 1.0
        case .standard: 0.85
        case .light: 0.6
        }
    }

    /// Whether to run `repeating` symbol effects (the live-status
    /// dot pulse, the empty-log sparkles). Cheap on Apple Silicon,
    /// noticeably draws GPU on older Intel — turn off in `.light`.
    public var repeatingSymbolEffectsAllowed: Bool {
        self != .light
    }

    /// Whether to use the mode-aware window-background pastel wash.
    /// Turn off on `.light` so the LogConsoleView's incremental
    /// scroll updates don't fight a fade-in animation behind them.
    public var animatedWindowBackgroundAllowed: Bool {
        self != .light
    }

    /// Maximum number of `LogEntry` rows held in memory. A lower
    /// cap makes the SwiftUI diff cheaper on every append; a
    /// higher cap means the user can scroll back further. We trade
    /// the latter for the former on slower hardware.
    public var maxLogEntries: Int {
        switch self {
        case .full: 1000
        case .standard: 600
        case .light: 300
        }
    }

    private static func pick(from host: HostMachine) -> PerformanceProfile {
        // Apple Silicon at any core count beats Intel at the same
        // count for SwiftUI animation work — the unified memory
        // architecture and the dedicated GPU side keep the
        // compositor responsive even on the lower-end chips.
        switch host.architecture {
        case .appleSilicon:
            return host.physicalCores >= 8 ? .full : .standard
        case .intel:
            return host.physicalCores >= 8 ? .standard : .light
        case .unknown:
            return .light
        }
    }
}
