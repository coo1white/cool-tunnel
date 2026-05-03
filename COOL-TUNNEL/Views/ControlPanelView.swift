// Views/ControlPanelView.swift
//
// v0.1.5.4: redesigned as a Maltese-pup mode picker.
//
// One row, four interaction surfaces:
//
//   [ Smart ] [ Global ] [ Local ]   ⏻ Stop   🩺 Diag   ⏱ Latency   ⚙ Settings
//
// The three mode chips are mutually exclusive (radio-style) — picking
// one while the proxy is running calls `switchMode(to:)`, which
// hot-swaps the active mode in place rather than forcing the user to
// stop first. That removes the awkward "Start Smart is greyed out
// because Global is running" state from earlier versions.
//
// macOS 26 features in use here:
//   - `.glassEffect()` on the wrapper card (via `pupCard`)
//   - `.symbolEffect(.bounce)` on the active chip's icon when the
//     mode changes
//   - `.sensoryFeedback(.selection, trigger:)` on chip taps
//   - `.contentTransition(.symbolEffect(.replace))` on the run-state
//     toggle icon

import SwiftUI

public struct ControlPanelView: View {
    @Environment(TunnelOrchestrator.self) private var orchestrator
    @Binding public var isShowingSettings: Bool

    public init(isShowingSettings: Binding<Bool>) {
        self._isShowingSettings = isShowingSettings
    }

    public var body: some View {
        HStack(spacing: 12) {
            modePicker
            Divider().frame(height: 28).opacity(0.3)
            stopButton
            diagnosticsButton
            latencyMenu
            Spacer()
            settingsButton
        }
        .padding(12)
        .pupCard(cornerRadius: 8)
        // Selection feedback on the trackpad — feels "genki" without
        // being noisy. macOS only honours certain feedback kinds on
        // hardware that supports them; the modifier no-ops elsewhere.
        .sensoryFeedback(.selection, trigger: orchestrator.activeMode)
        .sensoryFeedback(.success, trigger: orchestrator.isRunning) { _, new in new }
    }

    // MARK: - Mode picker (the headline change)

    /// Three radio-style chips wrapped in a pill rail. Tapping a chip
    /// while idle starts the proxy in that mode; while running, it
    /// hot-swaps via [`TunnelOrchestrator.switchMode(to:)`].
    private var modePicker: some View {
        HStack(spacing: 8) {
            modeChip(
                .smart,
                label: "Smart",
                system: "bolt.horizontal.fill"
            )
            modeChip(
                .global,
                label: "Global",
                system: "globe.americas.fill"
            )
            modeChip(
                .localOnly,
                label: "Local",
                system: "house.fill"
            )
        }
        .padding(4)
        .background {
            Capsule(style: .continuous).fill(.ultraThinMaterial)
        }
        .overlay {
            Capsule(style: .continuous).strokeBorder(.white.opacity(0.30), lineWidth: 0.5)
        }
    }

    /// One mode chip. `isActive` is true when the orchestrator is
    /// running AND in this mode — so a chip never looks selected when
    /// the proxy is actually stopped, even if it was the last-used
    /// mode.
    private func modeChip(_ mode: ProxyMode, label: String, system: String) -> some View {
        let isActive = orchestrator.isRunning && orchestrator.activeMode == mode
        let tint = CTPalette.accent(for: mode)
        // Tapping the *currently active* chip is a redundant request
        // — switchMode handles it as a no-op, but we save the tap
        // round-trip + visible "press" feedback by disabling it.
        let isCurrent = orchestrator.isRunning && orchestrator.activeMode == mode
        return Button {
            // Re-entry guard: a fast double-tap on the same chip
            // would otherwise queue two `switchMode` tasks. Both
            // serialise on the MainActor so it's not a correctness
            // bug, but the second task does redundant stop/start
            // work we can skip outright.
            guard !isCurrent else { return }
            Task {
                do {
                    try await orchestrator.switchMode(to: mode)
                } catch {
                    // `lastError` carries the user-facing surface;
                    // logging it here would be redundant.
                }
            }
        } label: {
            Label(label, systemImage: system)
                .symbolEffect(.bounce, options: .speed(1.3), value: isActive)
        }
        .buttonStyle(ModeChipStyle(isActive: isActive, tint: tint))
        .disabled(isCurrent)
        .help(modeHelp(for: mode))
    }

    private func modeHelp(for mode: ProxyMode) -> String {
        switch mode {
        case .smart:
            "Route the direct-domains list around the proxy; everything else through SOCKS."
        case .global:
            "Route every TCP connection through the proxy."
        case .localOnly:
            "Run naive on 127.0.0.1; leave the system proxy untouched."
        case .stopped:
            ""
        }
    }

    // MARK: - Secondary actions

    private var stopButton: some View {
        Button(role: .destructive) {
            Task { await orchestrator.stop() }
        } label: {
            Label("Stop", systemImage: "stop.fill")
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(SoftButtonStyle(tint: orchestrator.isRunning ? CTPalette.cherryRose : .secondary))
        .disabled(!orchestrator.isRunning)
    }

    private var diagnosticsButton: some View {
        Button {
            Task { await orchestrator.runDiagnostics() }
        } label: {
            Label("Diag", systemImage: "stethoscope")
        }
        .buttonStyle(SoftButtonStyle(tint: orchestrator.isRunning ? CTPalette.inkBlue : .secondary))
        .disabled(!orchestrator.isRunning)
    }

    private var latencyMenu: some View {
        Menu {
            Button("Smart route") {
                Task { await orchestrator.runLatencyTest(mode: .smart) }
            }
            Button("Global route") {
                Task { await orchestrator.runLatencyTest(mode: .global) }
            }
        } label: {
            Label("Latency", systemImage: "speedometer")
        }
        .menuStyle(.borderlessButton)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background {
            Capsule(style: .continuous).fill(.ultraThinMaterial)
        }
        .overlay {
            Capsule(style: .continuous).strokeBorder(
                (orchestrator.isRunning ? CTPalette.lilac : .secondary).opacity(0.30),
                lineWidth: 0.6
            )
        }
        .foregroundStyle(orchestrator.isRunning ? CTPalette.inkBlue : .secondary)
        .disabled(!orchestrator.isRunning)
        .fixedSize()
    }

    private var settingsButton: some View {
        Button {
            isShowingSettings = true
        } label: {
            Label("Settings", systemImage: "gearshape.fill")
        }
        .buttonStyle(SoftButtonStyle(tint: CTPalette.inkBlue))
    }
}
