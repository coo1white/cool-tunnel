// App/CoolTunnelApp.swift
//
// SwiftUI entry point. Owns the long-lived `TunnelOrchestrator` and hands
// it to the view hierarchy via the environment so leaf views never need to
// know about the engine subprocess directly.

import SwiftUI

@main
struct CoolTunnelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var orchestrator = TunnelOrchestrator.bootstrap()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(orchestrator)
                .frame(
                    minWidth: 780, idealWidth: 940, maxWidth: .infinity,
                    minHeight: 700, idealHeight: 820, maxHeight: .infinity
                )
                .task { await orchestrator.bootstrapIfNeeded() }
                .onDisappear {
                    Task { await orchestrator.shutdown() }
                }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 820, height: 700)
    }
}
