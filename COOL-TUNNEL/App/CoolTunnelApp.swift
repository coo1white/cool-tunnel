// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//
// This software is a sanctuary for personal privacy. Any
// redistribution or modification must strictly adhere to the
// AGPL-3.0 terms to ensure the spirit of freedom remains
// untainted.
//
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
        // **Menu-F#1 (v0.2):** wire the standard "Settings…" /
        // ⌘, contract. The app's settings live as an inline panel
        // inside `ContentView` (single-window architecture, see
        // file header), so the menu item posts a notification
        // that `ContentView` flips into `isShowingSettings = true`
        // — same surface the in-window gear button drives. We
        // deliberately do *not* introduce a separate `Settings`
        // scene; that would create a second window and re-open
        // the multi-window class of bugs the v0.1.5.8 single-
        // window refactor eliminated.
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NotificationCenter.default.post(
                        name: .openCoolTunnelSettings, object: nil)
                    // If the window is hidden (Cmd+W), bring it
                    // back so the inline Settings panel has a
                    // window to render in.
                    NSApp.activate(ignoringOtherApps: true)
                    if let main = NSApp.windows.first(where: {
                        $0.identifier?.rawValue == WindowID.main
                    }) {
                        main.makeKeyAndOrderFront(nil)
                    }
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }

        // **MenuBar-F#1 (v0.2):** first-class menu-bar status
        // item. Primary control surface for the proxy use case —
        // glance the glyph for state, click for mode switch +
        // Start/Stop without focus-stealing the main window. The
        // MenuBarExtra's label closure reads the orchestrator's
        // observable state, so the glyph swaps automatically on
        // run-state and error transitions.
        MenuBarExtra {
            MenuBarStatusContent()
                .environment(orchestrator)
        } label: {
            Image(systemName: menuBarSymbol(for: orchestrator))
        }
        .menuBarExtraStyle(.menu)

        // **Phase 2.4 (v0.2):** Acknowledgements window opened
        // from Settings → About → Acknowledgements…. Uses
        // `Window(_:id:)` (not `WindowGroup`) so the system
        // never spawns more than one — repeated clicks bring
        // the existing window forward instead of stacking
        // duplicates. Same single-window invariant the main
        // window relies on.
        Window("Acknowledgements", id: WindowID.acknowledgements) {
            AcknowledgementsView()
        }
        .defaultSize(width: 560, height: 560)
        .windowResizability(.contentSize)
    }
}

/// Maps the orchestrator's observable state to the SF Symbol shown
/// in the menu bar. **Shape, not just colour** — colour-blind users
/// should be able to read state at a glance: outline ring (off /
/// connecting), filled ring (running), warning triangle (error).
@MainActor
private func menuBarSymbol(for orchestrator: TunnelOrchestrator) -> String {
    if orchestrator.lastError != nil {
        return "exclamationmark.triangle.fill"
    }
    return orchestrator.isRunning
        ? "arrow.up.right.circle.fill"
        : "arrow.up.right.circle"
}

/// Centralised window identifiers. Used by `Window(_:id:)` and by
/// `AppDelegate` when it needs to find the single main window after
/// a Cmd+W hide.
enum WindowID {
    static let main = "cool-tunnel-main"
    /// Phase 2.4: Acknowledgements window opened from
    /// Settings → About → Acknowledgements….
    static let acknowledgements = "cool-tunnel-acknowledgements"
}

extension Notification.Name {
    /// Posted by the App-menu Settings… command (⌘,). `ContentView`
    /// observes this and flips `isShowingSettings` to true so the
    /// inline panel slides in. Decoupled via NotificationCenter
    /// because the App scene's `.commands` block can't easily mutate
    /// view-local @State without lifting the flag up to the
    /// orchestrator (which would mix transient UI state into the
    /// engine façade).
    static let openCoolTunnelSettings = Notification.Name(
        "space.coolwhite.naive.openSettings"
    )
}
