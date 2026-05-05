// Views/ControlPanelView.swift
//
// **Phase 2.1 (v0.2):** the custom mode-chip rail is replaced by
// a real `Picker(.segmented)` (renders as `NSSegmentedControl`) +
// a primary `Start` / `Stop` button styled `.borderedProminent`.
// Diagnostics, Latency, and Settings are standard `.bordered`
// buttons. Every CTPalette / SoftButtonStyle / pupCard reference
// is gone from this surface — the row sits on the inherited
// window background with no card around it, the same way Wi-Fi
// or Time Machine settings rows do.
//
// Behaviour:
//
//   - The Picker selection drives the *intent* — what mode the
//     proxy will run in. While stopped, the Start button reads
//     the selection. While running, changing the segment hot-
//     swaps (`switchMode(to:)`) immediately, the same UX the
//     menu-bar mode rows use.
//
//   - `transitionInFlight` and `userStopInFlight` (see
//     TunnelOrchestrator) cover the menu-bar / window race —
//     the Picker setter and the Start/Stop button both go
//     through `switchMode(...)`, never directly through
//     `start(...)` / `stop()`, so the lifecycle guard sees
//     every click.
//
//   - The Latency button is a `Menu` with two routes (Smart /
//     Global) — Local mode bypasses the proxy so a Local
//     latency probe has no proxied path to measure; that
//     option is shown disabled with an explanatory tooltip.

import SwiftUI
import os

/// Mode picker + lifecycle button + secondary actions.
public struct ControlPanelView: View {
    @Environment(TunnelOrchestrator.self) private var orchestrator
    @Binding public var isShowingSettings: Bool

    /// User-intent mode. Picker reads this when the proxy is
    /// stopped; while running it mirrors `orchestrator.activeMode`
    /// via the `.onChange` below.
    @State private var pendingMode: ProxyMode = .smart

    public init(isShowingSettings: Binding<Bool>) {
        self._isShowingSettings = isShowingSettings
    }

    public var body: some View {
        HStack(spacing: 10) {
            modePicker
            Spacer(minLength: 8)
            primaryButton
            diagnosticsButton
            latencyMenu
            settingsButton
        }
        // Sync `pendingMode` when the orchestrator's running mode
        // changes from another surface (menu-bar tap, deep link).
        // Keeps the Picker selection consistent with the engine's
        // truth without the Picker having to bind directly to the
        // orchestrator's `.stopped` sentinel.
        .onChange(of: orchestrator.activeMode) { _, new in
            if new != .stopped {
                pendingMode = new
            }
        }
    }

    // MARK: - Mode picker

    private var modePicker: some View {
        Picker("Mode", selection: modeBinding) {
            Text("Smart").tag(ProxyMode.smart)
            Text("Global").tag(ProxyMode.global)
            Text("Local").tag(ProxyMode.localOnly)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 260)
        .disabled(orchestrator.selectedProfile == nil)
        .help(modeHelp)
    }

    /// Two-way binding that:
    ///   - **Reads** the running mode when active, otherwise the
    ///     user's pending intent.
    ///   - **Writes** the new selection through `switchMode(...)`
    ///     when the proxy is already running (instant hot-swap),
    ///     and only updates `pendingMode` when stopped (the Start
    ///     button is the explicit activate trigger in that case).
    private var modeBinding: Binding<ProxyMode> {
        Binding(
            get: {
                orchestrator.isRunning && orchestrator.activeMode != .stopped
                    ? orchestrator.activeMode
                    : pendingMode
            },
            set: { newValue in
                pendingMode = newValue
                guard orchestrator.isRunning else { return }
                Task {
                    do {
                        try await orchestrator.switchMode(to: newValue)
                    } catch {
                        Self.uiLogger.error(
                            "mode hot-swap to \(newValue.title, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                        )
                    }
                }
            }
        )
    }

    private var modeHelp: String {
        switch pendingMode {
        case .smart:
            "Smart: route the direct-domains list around the proxy; everything else through SOCKS."
        case .global:
            "Global: route every TCP connection through the proxy."
        case .localOnly:
            "Local: run naive on 127.0.0.1; leave the system proxy untouched."
        case .stopped:
            ""
        }
    }

    // MARK: - Start / Stop primary button

    private var primaryButton: some View {
        Button {
            Task { await togglePrimary() }
        } label: {
            Label(
                orchestrator.isRunning ? "Stop" : "Start",
                systemImage: orchestrator.isRunning ? "stop.fill" : "play.fill"
            )
            .frame(minWidth: 60)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .tint(orchestrator.isRunning ? .red : .accentColor)
        .disabled(orchestrator.selectedProfile == nil)
        .help(orchestrator.isRunning ? "Stop the proxy" : "Start in \(pendingMode.title) mode")
        .accessibilityLabel(orchestrator.isRunning ? "Stop proxy" : "Start proxy in \(pendingMode.title) mode")
    }

    private func togglePrimary() async {
        let target: ProxyMode = orchestrator.isRunning ? .stopped : pendingMode
        do {
            try await orchestrator.switchMode(to: target)
        } catch {
            Self.uiLogger.error(
                "primary toggle (target=\(target.rawValue, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Secondary actions

    private var diagnosticsButton: some View {
        Button {
            Task { await orchestrator.runDiagnostics() }
        } label: {
            Label("Diagnostics", systemImage: "stethoscope")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .disabled(!orchestrator.isRunning)
        .help("Run diagnostics through the active proxy connection.")
        .accessibilityLabel("Run diagnostics")
    }

    private var latencyMenu: some View {
        Menu {
            Button("Smart route") {
                Task { await orchestrator.runLatencyTest(mode: .smart) }
            }
            Button("Global route") {
                Task { await orchestrator.runLatencyTest(mode: .global) }
            }
            Button("Local route (bypasses proxy)") {}
                .disabled(true)
                .help("Local mode runs naive on 127.0.0.1 without changing the system proxy — there is no proxied path to measure.")
        } label: {
            Label("Latency", systemImage: "speedometer")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .frame(width: 36)
        .disabled(!orchestrator.isRunning)
        .help("Measure DNS, connect, TLS, and first-byte timings through the proxy.")
        .accessibilityLabel("Latency test menu")
    }

    private var settingsButton: some View {
        Button {
            isShowingSettings = true
        } label: {
            Label("Settings", systemImage: "gear")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .keyboardShortcut(",", modifiers: .command)
        .help("Open Settings")
        .accessibilityLabel("Settings")
    }

    /// **Engine-F#P2.4 (v0.2):** project-wide UI logger for the
    /// main-window control surface. Same subsystem as
    /// CoreClient / Orchestrator so a single `log show` predicate
    /// captures the full failure path (UI tap → orchestrator →
    /// engine wire error).
    private static let uiLogger = Logger.cooltunnel("UI.ControlPanel")
}
