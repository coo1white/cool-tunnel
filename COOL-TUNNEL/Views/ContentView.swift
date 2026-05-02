// Views/ContentView.swift
//
// Composition root: lays out the four panels and wires them all to the
// shared `TunnelOrchestrator` from the environment. Each subview owns its
// own slice of behaviour; this file does no business logic.

import SwiftUI

public struct ContentView: View {
    @Environment(TunnelOrchestrator.self) private var orchestrator
    @State private var isShowingSettings = false

    public init() {}

    public var body: some View {
        VStack(spacing: 18) {
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
        .sheet(isPresented: $isShowingSettings) {
            SettingsView()
        }
    }
}

#Preview {
    ContentView()
        .environment(TunnelOrchestrator.bootstrap())
}
