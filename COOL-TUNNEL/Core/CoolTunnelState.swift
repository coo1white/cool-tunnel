// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
// Core/CoolTunnelState.swift
//
// Declarative application schema for the SwiftUI layer. The
// orchestrator owns effects; views receive one of these values and
// emit `TunnelIntent` values back upward.

import Foundation

/// Transient UI-only state that is still important enough to name.
///
/// **Heng / Silent Operator invariant:** `pendingMode` is the
/// operator's declared next mode, not the engine's current mode. Keep
/// it explicit so future refactors (human or AI-led) do not infer the
/// segmented picker directly from `activeMode` and reintroduce the
/// click-lag/blink bugs that the hot-swap work removed.
public struct CoolTunnelUIState: Sendable, Equatable {
    public var isShowingSettings: Bool
    public var pendingMode: ProxyMode

    public init(
        isShowingSettings: Bool = false,
        pendingMode: ProxyMode = .smart
    ) {
        self.isShowingSettings = isShowingSettings
        self.pendingMode = pendingMode
    }
}

/// Explicit user intent emitted by SwiftUI controls.
///
/// UI surfaces should not call engine lifecycle methods directly.
/// They send one of these values to the composition root or the
/// orchestrator. That keeps the view hierarchy declarative: state in,
/// intent out, effects handled in one predictable logic layer.
public enum TunnelIntent: Sendable, Equatable {
    case switchMode(ProxyMode)
    case toggleRunning(preferredMode: ProxyMode)
    case runDiagnostics
    case runLatencyTest(ProxyTestMode)
    case runDebugHandshake
    case dismissError
    case clearLogs
}

/// Strict, nested view-state schema for Cool Tunnel.
///
/// The shape is intentionally boring and serialisable-looking:
/// connection, header, controls, menu bar, profiles, log, diagnostics,
/// settings, resources. This gives an LLM a stable map of the app
/// without requiring it to reverse-engineer scattered `@Observable`
/// fields or leaf-view side effects.
public struct CoolTunnelViewState: Sendable, Equatable {
    public var ui: CoolTunnelUIState
    public var connection: Connection
    public var header: Header
    public var controlPanel: ControlPanel
    public var menuBar: MenuBar
    public var profiles: Profiles
    public var activityLog: ActivityLog
    public var diagnostics: Diagnostics
    public var settings: AppSettings
    public var resources: Resources

    public init(
        ui: CoolTunnelUIState,
        connection: Connection,
        header: Header,
        controlPanel: ControlPanel,
        menuBar: MenuBar,
        profiles: Profiles,
        activityLog: ActivityLog,
        diagnostics: Diagnostics,
        settings: AppSettings,
        resources: Resources
    ) {
        self.ui = ui
        self.connection = connection
        self.header = header
        self.controlPanel = controlPanel
        self.menuBar = menuBar
        self.profiles = profiles
        self.activityLog = activityLog
        self.diagnostics = diagnostics
        self.settings = settings
        self.resources = resources
    }
}

extension CoolTunnelViewState {
    /// Engine-facing connection state, stripped of implementation
    /// detail. Views can render this without knowing about core
    /// subprocesses, PAC files, or `networksetup`.
    public struct Connection: Sendable, Equatable {
        public var isRunning: Bool
        public var activeMode: ProxyMode
        public var sleepWakeState: SleepWakeState
        public var firewallState: FirewallState
        public var error: ErrorBanner?

        public init(
            isRunning: Bool,
            activeMode: ProxyMode,
            sleepWakeState: SleepWakeState,
            firewallState: FirewallState,
            error: ErrorBanner?
        ) {
            self.isRunning = isRunning
            self.activeMode = activeMode
            self.sleepWakeState = sleepWakeState
            self.firewallState = firewallState
            self.error = error
        }
    }

    /// Error-banner payload. `layer` is optional because some failures
    /// are operational rather than classifiable as ISP / VPS /
    /// Local Kernel.
    public struct ErrorBanner: Sendable, Equatable {
        public var message: String
        public var layer: ErrorLayer?

        public init(message: String, layer: ErrorLayer?) {
            self.message = message
            self.layer = layer
        }
    }

    /// Header state maps directly to the main window's top chrome.
    ///
    /// **Heng / Silent Operator invariant:** status copy must be
    /// factual and terse. The app should keep operating or recover
    /// quietly when it can, and only surface the smallest actionable
    /// signal when it cannot.
    public struct Header: Sendable, Equatable {
        public var statusPill: StatusPill
        public var errorBanner: ErrorBanner?
        public var showsFirewallBadge: Bool

        public init(
            statusPill: StatusPill,
            errorBanner: ErrorBanner?,
            showsFirewallBadge: Bool
        ) {
            self.statusPill = statusPill
            self.errorBanner = errorBanner
            self.showsFirewallBadge = showsFirewallBadge
        }
    }

    public struct StatusPill: Sendable, Equatable {
        public var headline: String
        public var tint: StatusTint

        public init(headline: String, tint: StatusTint) {
            self.headline = headline
            self.tint = tint
        }
    }

    /// Semantic colour token for the status pill. SwiftUI maps this
    /// to `Color` at the edge so the schema stays platform-neutral.
    public enum StatusTint: String, Sendable, Codable, Equatable {
        case secondary
        case green
        case yellow
        case red
    }

    /// Main lifecycle-control state.
    public struct ControlPanel: Sendable, Equatable {
        public var isRunning: Bool
        public var activeMode: ProxyMode
        public var hasSelectedProfile: Bool
        public var selectedProfileIsStartable: Bool
        public var selectedProfileCanRequestStart: Bool
        public var modeOptions: [ModeOption]

        public init(
            isRunning: Bool,
            activeMode: ProxyMode,
            hasSelectedProfile: Bool,
            selectedProfileIsStartable: Bool,
            selectedProfileCanRequestStart: Bool,
            modeOptions: [ModeOption] = ModeOption.defaultOptions
        ) {
            self.isRunning = isRunning
            self.activeMode = activeMode
            self.hasSelectedProfile = hasSelectedProfile
            self.selectedProfileIsStartable = selectedProfileIsStartable
            self.selectedProfileCanRequestStart = selectedProfileCanRequestStart
            self.modeOptions = modeOptions
        }

        public var isModePickerEnabled: Bool {
            hasSelectedProfile
        }

        public var isPrimaryActionEnabled: Bool {
            isRunning || selectedProfileCanRequestStart
        }
    }

    public struct ModeOption: Sendable, Identifiable, Equatable {
        public var id: ProxyMode
        public var label: String
        public var help: String

        public init(id: ProxyMode, label: String, help: String) {
            self.id = id
            self.label = label
            self.help = help
        }

        public static let defaultOptions: [ModeOption] = [
            ModeOption(
                id: .smart,
                label: "Smart",
                help: "Smart: route the direct-domains list around the proxy; everything else through SOCKS."
            ),
            ModeOption(
                id: .global,
                label: "Global",
                help: "Global: route every TCP connection through the proxy."
            ),
            ModeOption(
                id: .localOnly,
                label: "Local",
                help: "Local: run naive on 127.0.0.1; leave the system proxy untouched."
            ),
        ]
    }

    /// Menu-bar projection. Kept separate from `Header` because menu
    /// extras have different affordances: terse header text, checked
    /// rows, and an optional Stop command.
    public struct MenuBar: Sendable, Equatable {
        public var statusLine: String
        public var symbolName: String
        public var isRunning: Bool
        public var activeMode: ProxyMode
        public var hasSelectedProfile: Bool
        public var selectedProfileCanRequestStart: Bool

        public init(
            statusLine: String,
            symbolName: String,
            isRunning: Bool,
            activeMode: ProxyMode,
            hasSelectedProfile: Bool,
            selectedProfileCanRequestStart: Bool
        ) {
            self.statusLine = statusLine
            self.symbolName = symbolName
            self.isRunning = isRunning
            self.activeMode = activeMode
            self.hasSelectedProfile = hasSelectedProfile
            self.selectedProfileCanRequestStart = selectedProfileCanRequestStart
        }
    }

    public struct Profiles: Sendable, Equatable {
        public var all: [Profile]
        public var selectedID: String?
        public var selected: Profile?

        public init(all: [Profile], selectedID: String?, selected: Profile?) {
            self.all = all
            self.selectedID = selectedID
            self.selected = selected
        }
    }

    public struct ActivityLog: Sendable, Equatable {
        public var entries: [LogEntry]
        public var canExport: Bool

        public init(entries: [LogEntry]) {
            self.entries = entries
            self.canExport = !entries.isEmpty
        }
    }

    public struct Diagnostics: Sendable, Equatable {
        public var lastDiagnosticReport: DiagnosticReport?
        public var lastLatencyReport: LatencyReport?

        public init(
            lastDiagnosticReport: DiagnosticReport?,
            lastLatencyReport: LatencyReport?
        ) {
            self.lastDiagnosticReport = lastDiagnosticReport
            self.lastLatencyReport = lastLatencyReport
        }
    }

    public struct Resources: Sendable, Equatable {
        public var activeNaiveDescriptor: NaiveBinaryDescriptor?

        public init(activeNaiveDescriptor: NaiveBinaryDescriptor?) {
            self.activeNaiveDescriptor = activeNaiveDescriptor
        }
    }
}
