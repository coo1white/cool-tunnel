// App/CoolTunnelApp.swift
//
// SwiftUI entry point. Owns the long-lived `TunnelOrchestrator` and
// hands it to the view hierarchy via the environment so leaf views
// never need to know about the engine subprocess directly.
//
// v0.1.5.8 fix: switched from `WindowGroup` to `Window(_:id:)` so
// the app is single-window by construction. Earlier versions used
// `WindowGroup`, which lets SwiftUI create additional windows on
// state restoration / dock reopen — the user reported "Cmd+W +
// reopen produces extra windows", which was exactly that. Single
// `Window` scenes can't multiply.
//
// Cmd+W still hides the window (not closes), via the AppDelegate's
// local key monitor; reopen brings the same hidden window back to
// the front. `orchestrator.shutdown()` is no longer wired to the
// view's `.onDisappear` (which fires on hide too) — it now runs
// only on real app termination from `AppDelegate.applicationWillTerminate`.

import SwiftUI

@main
struct CoolTunnelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var orchestrator = TunnelOrchestrator.bootstrap()

    var body: some Scene {
        Window("Cool Tunnel", id: WindowID.main) {
            ContentView()
                .environment(orchestrator)
                // Min sizes guarantee the four-pane stack always
                // fits without truncation. Ideal matches `defaultSize`
                // below so the first-launch window opens at the
                // intended dimensions; previous v0.1.7 had a 940 vs
                // 820 mismatch that made first launch jump.
                .frame(
                    minWidth: 780, idealWidth: 820, maxWidth: .infinity,
                    minHeight: 700, idealHeight: 820, maxHeight: .infinity
                )
                .task {
                    await orchestrator.bootstrapIfNeeded()
                    // Hand the orchestrator to the AppDelegate so
                    // `applicationWillTerminate` can call shutdown
                    // on real quit. We deliberately do *not* wire
                    // shutdown to the view's `.onDisappear` because
                    // Cmd+W hides the window and that's not the
                    // user asking the engine to stop.
                    appDelegate.orchestrator = orchestrator
                }
        }
        // `.automatic` honours the content's min frame as the
        // resize floor without using `maxWidth: .infinity` as the
        // ceiling — `.contentSize` paired with `maxWidth: .infinity`
        // lets the user drag the window to absurd dimensions.
        .windowResizability(.automatic)
        .defaultSize(width: 820, height: 820)
    }
}

/// Centralised window identifiers. Used by `Window(_:id:)` and by
/// `AppDelegate` when it needs to find the single main window after
/// a Cmd+W hide.
enum WindowID {
    static let main = "cool-tunnel-main"
}
