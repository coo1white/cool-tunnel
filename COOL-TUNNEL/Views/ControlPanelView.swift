// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
// Views/ControlPanelView.swift
//
// Schema-driven control surface. The row is a pure rendering of
// `CoolTunnelViewState.ControlPanel` plus the local draft
// `pendingMode`; operator actions are emitted as `TunnelIntent`
// values and resolved by `TunnelOrchestrator`.

import SwiftUI
import os

/// Mode picker + lifecycle button + secondary actions.
public struct ControlPanelView: View {
    public let state: CoolTunnelViewState.ControlPanel
    @Binding public var pendingMode: ProxyMode
    @Binding public var isShowingSettings: Bool
    public let onIntent: (TunnelIntent) -> Void

    public init(isShowingSettings: Binding<Bool>) {
        self.state = CoolTunnelViewState.ControlPanel(
            isRunning: false,
            activeMode: .stopped,
            hasSelectedProfile: false,
            selectedProfileIsStartable: false,
            selectedProfileCanRequestStart: false
        )
        self._pendingMode = .constant(.smart)
        self._isShowingSettings = isShowingSettings
        self.onIntent = { _ in }
    }

    /// Schema-first initializer used by `ContentView`.
    ///
    /// **Heng / Silent Operator invariant:** this row renders a
    /// declared state and emits `TunnelIntent`; it does not own the
    /// tunnel lifecycle. The binding is only the operator's draft mode
    /// so the segmented control responds instantly while the
    /// orchestrator quietly performs a start or hot-swap.
    public init(
        state: CoolTunnelViewState.ControlPanel,
        pendingMode: Binding<ProxyMode>,
        isShowingSettings: Binding<Bool>,
        onIntent: @escaping (TunnelIntent) -> Void
    ) {
        self.state = state
        self._pendingMode = pendingMode
        self._isShowingSettings = isShowingSettings
        self.onIntent = onIntent
    }

    public var body: some View {
        HStack(spacing: 10) {
            modePicker
            primaryButton
            diagnosticsButton
            debugHandshakeButton
            latencyMenu
            settingsButton
        }
        // Keep external mode changes (menu bar, recovery, deep link)
        // reflected in the operator's draft selection. `.stopped`
        // intentionally does not overwrite the draft; when idle, the
        // selection remains the next mode Start will use.
        .onChange(of: state.activeMode) { _, new in
            if new != .stopped {
                pendingMode = new
            }
        }
    }

    // MARK: - Mode picker

    private var modePicker: some View {
        Picker("Mode", selection: modeBinding) {
            ForEach(state.modeOptions) { option in
                Text(option.label).tag(option.id)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 220)
        .disabled(!state.isModePickerEnabled)
        .help(modeHelp)
    }

    /// Two-way binding for the segmented mode picker.
    ///
    /// **Reads** `pendingMode`, the operator's immediate intent.
    /// **Writes** emit `.switchMode` only when the proxy is already
    /// running. When stopped, Start remains the explicit activation
    /// command. This split is the Heng contract for a calm control
    /// surface: acknowledge intent instantly, let the orchestrator do
    /// the quiet operational work.
    private var modeBinding: Binding<ProxyMode> {
        Binding(
            get: { pendingMode },
            set: { newValue in
                pendingMode = newValue
                guard state.isRunning else { return }
                onIntent(.switchMode(newValue))
                Self.uiLogger.debug(
                    "mode intent emitted for \(newValue.title, privacy: .public)"
                )
            }
        )
    }

    private var modeHelp: String {
        if let option = state.modeOptions.first(where: { $0.id == pendingMode }) {
            return option.help
        }
        return ""
    }

    // MARK: - Start / Stop primary button

    private var primaryButton: some View {
        Button {
            onIntent(.toggleRunning(preferredMode: pendingMode))
        } label: {
            Label(
                state.isRunning ? "Stop" : "Start",
                systemImage: state.isRunning ? "stop.fill" : "play.fill"
            )
            // Wider than either label needs so the icon row to
            // the right never reflows when the proxy starts /
            // stops. The unused trailing space inside the
            // borderedProminent shape is invisible.
            .frame(minWidth: 72)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .tint(state.isRunning ? .red : .accentColor)
        .disabled(!state.isPrimaryActionEnabled)
        .help(primaryButtonHelp)
        .accessibilityLabel(primaryButtonAccessibilityLabel)
    }

    private var primaryButtonHelp: String {
        if state.isRunning { return "Stop the proxy" }
        guard state.hasSelectedProfile else {
            return "Pick or create a profile first"
        }
        if !state.selectedProfileCanRequestStart {
            return "Fix server, username, and local port before starting"
        }
        if !state.selectedProfileIsStartable {
            return "Password will be checked when you start"
        }
        return "Start in \(pendingMode.title) mode"
    }

    private var primaryButtonAccessibilityLabel: String {
        if state.isRunning { return "Stop proxy" }
        guard state.hasSelectedProfile else {
            return "Start disabled — pick or create a profile first"
        }
        if !state.selectedProfileCanRequestStart {
            return "Start disabled — fix server, username, and local port"
        }
        if !state.selectedProfileIsStartable {
            return "Start proxy in \(pendingMode.title) mode; password will be checked first"
        }
        return "Start proxy in \(pendingMode.title) mode"
    }

    // MARK: - Secondary actions
    //
    // Every secondary control sits in a 30×22 fixed frame via
    // `IconBarButton` so the toolbar reads as an even cluster of
    // equally-sized cells regardless of which SF Symbol each one
    // happens to carry. Pre-refactor the row jittered when an
    // adjacent button enabled / disabled — the system's bordered
    // button sizes to glyph width, and `stethoscope` /
    // `network.badge.shield.half.filled` / `gear` / `speedometer`
    // are four very different widths.

    private var diagnosticsButton: some View {
        IconBarButton(
            systemImage: "stethoscope",
            help: "Run diagnostics through the active proxy connection.",
            accessibilityLabel: "Run diagnostics",
            isEnabled: state.isRunning
        ) {
            onIntent(.runDiagnostics)
        }
    }

    private var debugHandshakeButton: some View {
        IconBarButton(
            systemImage: "network.badge.shield.half.filled",
            help: "Run a temporary reference-proxy handshake probe and log first-byte hex evidence.",
            accessibilityLabel: "Debug handshake",
            isEnabled: state.selectedProfileCanRequestStart
        ) {
            onIntent(.runDebugHandshake)
        }
    }

    private var latencyMenu: some View {
        Menu {
            Button("Smart route") {
                onIntent(.runLatencyTest(.smart))
            }
            Button("Global route") {
                onIntent(.runLatencyTest(.global))
            }
            Button("Local route (bypasses proxy)") {}
                .disabled(true)
                .help(
                    "Local mode runs sing-box on 127.0.0.1 without changing the system proxy — there is no proxied path to measure."
                )
        } label: {
            Image(systemName: "speedometer")
                .frame(width: 16, height: 16)
        }
        .menuStyle(.borderlessButton)
        // Visible caret distinguishes the menu from the bordered
        // single-action icon buttons on either side — without it
        // a user clicking the speedometer would be surprised by a
        // popover rather than an immediate action. The 36 pt
        // width accommodates the caret next to the glyph; the
        // height matches IconBarButton so the row of cells reads
        // as a uniform horizontal strip.
        .menuIndicator(.visible)
        .frame(width: 36, height: 22)
        .disabled(!state.isRunning)
        .help("Measure DNS, connect, TLS, and first-byte timings through the proxy.")
        .accessibilityLabel("Latency test menu")
    }

    private var settingsButton: some View {
        IconBarButton(
            systemImage: "gear",
            help: "Open Settings",
            accessibilityLabel: "Settings"
        ) {
            isShowingSettings = true
        }
        .keyboardShortcut(",", modifiers: .command)
    }

    /// Project-wide UI logger for the main-window control surface.
    /// The actual tunnel work is logged by `TunnelOrchestrator`, but
    /// keeping this trace makes "tap -> intent -> engine" visible in
    /// one `log show` predicate when support needs it.
    private static let uiLogger = Logger.cooltunnel("UI.ControlPanel")
}
