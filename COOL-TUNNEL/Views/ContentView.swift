// Views/ContentView.swift
//
// Composition root: lays out the four panels and wires them all to
// the shared `TunnelOrchestrator` from the environment. v0.1.5.4
// adds a mode-aware pastel window background so the four cards float
// on a colour that matches the active proxy mode.
//
// Each subview owns its own slice of behaviour; this file does no
// business logic.

import SwiftUI

public struct ContentView: View {
    @Environment(TunnelOrchestrator.self) private var orchestrator
    @State private var isShowingSettings = false

    public init() {}

    public var body: some View {
        VStack(spacing: 14) {
            HeaderView(
                isRunning: orchestrator.isRunning,
                activeMode: orchestrator.activeMode,
                firewallState: orchestrator.firewallState
            )

            ControlPanelView(
                isShowingSettings: $isShowingSettings
            )

            ConnectionFormView()

            LogConsoleView()
                .frame(minHeight: 240)
        }
        .padding(20)
        .background {
            // Mode-aware pastel wash: stays subtle in idle, leans
            // into the chosen mode colour while the proxy is running.
            // The window itself becomes a mood ring.
            //
            // On the `.light` performance tier (older Intel Macs)
            // we drop the gradient overlay and the cross-fade
            // animation — the static cream tint stays so the cards
            // still feel framed, but the compositor doesn't have to
            // re-blend a full-window gradient on every state change.
            ZStack {
                CTPalette.cream.opacity(0.4)
                if PerformanceProfile.current.animatedWindowBackgroundAllowed {
                    CTPalette.dreamGradient(for: orchestrator.activeMode)
                        .opacity(orchestrator.isRunning ? 0.18 : 0.08)
                }
            }
            .ignoresSafeArea()
            .animation(
                PerformanceProfile.current.animatedWindowBackgroundAllowed
                    ? .easeInOut(duration: 0.6 * PerformanceProfile.current.animationScale)
                    : nil,
                value: orchestrator.activeMode
            )
            .animation(
                PerformanceProfile.current.animatedWindowBackgroundAllowed
                    ? .easeInOut(duration: 0.6 * PerformanceProfile.current.animationScale)
                    : nil,
                value: orchestrator.isRunning
            )
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView()
        }
    }
}

#Preview {
    ContentView()
        .environment(TunnelOrchestrator.bootstrap())
}
