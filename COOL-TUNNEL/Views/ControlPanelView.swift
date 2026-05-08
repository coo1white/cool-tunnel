// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
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
        // **v2.0.8 (UI compaction):** the previous layout had a
        // flexible `Spacer(minLength: 8)` between the mode
        // picker and the buttons, so the controls sprayed out
        // across the whole window width with a wide empty gap
        // in the middle — exactly the wasted space the user
        // flagged in the screenshot. v2.0.8 collapses that to a
        // fixed 10-pt gap. ControlPanelView is now a tight
        // primary-action cluster (Picker + Start + secondary
        // buttons), and the breathing room comes from the
        // outer Spacer in `ContentView.mergedHeaderRow` between
        // the status pill and this cluster.
        HStack(spacing: 10) {
            modePicker
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
        // **v2.0.8 (UI compaction):** trimmed from 260 → 220.
        // The merged single-row header (status pill + this
        // picker + Start + secondary buttons + firewall badge)
        // needs to fit at the 780-pt window minWidth with the
        // firewall pill on; 260 left no margin. Three short
        // labels ("Smart" / "Global" / "Local") still render
        // comfortably at 220 — checked against the system's
        // segment glyph metrics.
        .frame(maxWidth: 220)
        .disabled(orchestrator.selectedProfile == nil)
        .help(modeHelp)
    }

    /// Two-way binding for the segmented mode picker.
    ///
    /// **Reads** `pendingMode` — the user's most recent click — so
    /// the picker reflects intent instantly. The orchestrator's
    /// `activeMode` catches up over the next ~200-500 ms while the
    /// engine restarts; reading `activeMode` directly would make the
    /// picker visibly lag the click by that long, which is the same
    /// "the UI feels stuck" symptom that motivated UX-F#5.
    ///
    /// **Writes** the new selection through `switchMode(...)` when
    /// the proxy is already running (instant hot-swap), and only
    /// updates `pendingMode` when stopped (the Start button is the
    /// explicit activate trigger in that case).
    ///
    /// Pre-UX-F#5 the binding read `activeMode` while running and
    /// `pendingMode` while stopped. That worked only because
    /// `switchMode` *also* flickered `isRunning` / `activeMode`
    /// through `.stopped` mid-swap, which let the binding fall
    /// through to `pendingMode` for a few ms. Now that the
    /// orchestrator preserves the public state across a hot-swap,
    /// the picker has to read `pendingMode` directly to stay
    /// responsive — the two UI properties (button stability + picker
    /// responsiveness) have to be solved on both sides.
    private var modeBinding: Binding<ProxyMode> {
        Binding(
            get: { pendingMode },
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
        .disabled(primaryButtonDisabled)
        .help(primaryButtonHelp)
        .accessibilityLabel(primaryButtonAccessibilityLabel)
    }

    /// Disable Start when the selected profile is missing or
    /// has empty required fields. Stop is always enabled while
    /// running (so the user can recover from any state).
    private var primaryButtonDisabled: Bool {
        if orchestrator.isRunning { return false }
        guard let profile = orchestrator.selectedProfile else { return true }
        return !profile.isStartable
    }

    private var primaryButtonHelp: String {
        if orchestrator.isRunning { return "Stop the proxy" }
        guard let profile = orchestrator.selectedProfile else {
            return "Pick or create a profile first"
        }
        if !profile.isStartable {
            return "Fill in server, username, password, and local port to start"
        }
        return "Start in \(pendingMode.title) mode"
    }

    private var primaryButtonAccessibilityLabel: String {
        if orchestrator.isRunning { return "Stop proxy" }
        guard let profile = orchestrator.selectedProfile else {
            return "Start disabled — pick or create a profile first"
        }
        if !profile.isStartable {
            return "Start disabled — fill in server, username, password, and local port"
        }
        return "Start proxy in \(pendingMode.title) mode"
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
                .help(
                    "Local mode runs naive on 127.0.0.1 without changing the system proxy — there is no proxied path to measure."
                )
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
