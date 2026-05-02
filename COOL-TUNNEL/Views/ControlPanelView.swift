// Views/ControlPanelView.swift
//
// Action buttons: start in each mode, stop, run diagnostics, and the
// settings sheet trigger. All actions delegate to the orchestrator.

import SwiftUI

public struct ControlPanelView: View {
    @Environment(TunnelOrchestrator.self) private var orchestrator
    @Binding public var isShowingSettings: Bool

    public init(isShowingSettings: Binding<Bool>) {
        self._isShowingSettings = isShowingSettings
    }

    public var body: some View {
        HStack(spacing: 10) {
            startButton(mode: .smart, label: "Start Smart", system: "bolt.horizontal.fill")
            startButton(mode: .global, label: "Start Global", system: "globe")

            Button(role: .destructive) {
                Task { await orchestrator.stop() }
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .disabled(!orchestrator.isRunning)

            Divider().frame(height: 22)

            Button {
                Task { await orchestrator.runDiagnostics() }
            } label: {
                Label("Diagnostics", systemImage: "stethoscope")
            }
            .disabled(!orchestrator.isRunning)

            Menu {
                Button("Smart") {
                    Task { await orchestrator.runLatencyTest(mode: .smart) }
                }
                Button("Global") {
                    Task { await orchestrator.runLatencyTest(mode: .global) }
                }
            } label: {
                Label("Latency Test", systemImage: "speedometer")
            }
            .disabled(!orchestrator.isRunning)

            Spacer()

            Button {
                isShowingSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }
    }

    private func startButton(mode: ProxyMode, label: String, system: String) -> some View {
        Button {
            Task {
                do { try await orchestrator.start(mode: mode) } catch { /* surfaced via lastError */  }
            }
        } label: {
            Label(label, systemImage: system)
        }
        .disabled(orchestrator.isRunning)
    }
}
