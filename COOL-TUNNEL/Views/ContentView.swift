// Views/ContentView.swift
//
// Composition root: lays out the four main panels and wires them
// to the shared `TunnelOrchestrator` from the environment. v0.1.5.8
// changes Settings from a modal sheet into an **inline panel** —
// tapping the gear swaps the four-panel stack for the Settings
// view inside the same window, with a Back button (Cmd+W also
// works) that returns to the main view.
//
// **Phase 2.1 visual identity (v0.2):** the mode-aware pastel
// gradient window background and the `pupCard` framing on every
// pane were the loudest "doesn't look like a Mac app" signals from
// the v2.0 audit. Both removed: the window now uses the system's
// default `.windowBackground` material (inherits Light, Dark,
// Increased Contrast, accent tinting for free), and the panes
// stand on it directly without per-card chrome — the same way
// Mail / System Settings / TextEdit lay out.
//
// Each subview owns its own slice of behaviour; this file does no
// business logic.

import SwiftUI

/// Composition root for the single-window app. Swaps between the
/// four-panel main stack and the inline Settings view based on
/// `isShowingSettings`; renders the mode-aware pastel window
/// background underneath both.
public struct ContentView: View {
    @Environment(TunnelOrchestrator.self) private var orchestrator
    @State private var isShowingSettings = false

    public init() {}

    public var body: some View {
        ZStack {
            // Always render the main stack underneath. When Settings
            // is shown it sits on top with its own opaque background;
            // doing it this way keeps the window background animation
            // continuous instead of restarting on every panel swap.
            mainStack
                .opacity(isShowingSettings ? 0 : 1)
                .allowsHitTesting(!isShowingSettings)

            if isShowingSettings {
                // Inline Settings panel. Cmd+W and the Back button
                // both flip `isShowingSettings = false`; the
                // AppDelegate's window-hide handling on Cmd+W is
                // shadowed by the Back button's keyboard shortcut
                // while this view is in the responder chain.
                SettingsView(isShowing: $isShowingSettings)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isShowingSettings)
        // **Phase 2.1 (v0.2):** no `.background { … }` — the
        // window inherits the system's `.windowBackground`
        // material, which respects Light / Dark / Increased
        // Contrast / accent tint with no per-state animation.
        // Apply the user's appearance choice. `.system` returns
        // nil from `colorScheme`, which leaves the appearance to
        // follow `NSAppearance.current` (the macOS system
        // setting). `.light` / `.dark` lock the app regardless
        // of the system.
        .preferredColorScheme(orchestrator.settings.appearanceMode.colorScheme)
        // **Menu-F#1 (v0.2):** observe ⌘, / "Settings…" from the
        // App scene's CommandGroup. Flipping `isShowingSettings`
        // here keeps the inline-panel architecture intact — the
        // menu item drives the same surface as the in-window
        // gear button, so users have one Settings, two ways in.
        .onReceive(
            NotificationCenter.default.publisher(for: .openCoolTunnelSettings)
        ) { _ in
            isShowingSettings = true
        }
    }

    private var mainStack: some View {
        VStack(spacing: 0) {
            HeaderView(
                isRunning: orchestrator.isRunning,
                activeMode: orchestrator.activeMode,
                firewallState: orchestrator.firewallState,
                lastError: orchestrator.lastError,
                onDismissError: { orchestrator.dismissLastError() }
            )
            .padding(.horizontal, 20)
            .padding(.top, 16)

            ControlPanelView(
                isShowingSettings: $isShowingSettings
            )
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            ConnectionFormView()

            LogConsoleView()
                .frame(minHeight: 220)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
        }
    }
}

#if DEBUG
    // Wrapped in `#if DEBUG` so the preview's `bootstrap()` —
    // which spawns its own `cool-tunnel-core` subprocess — is
    // compiled out of Release. Without the guard the launched app
    // would fork a *second* engine alongside the one
    // `CoolTunnelApp` already owns, leaving two PIDs in `ps`.
    #Preview {
        ContentView()
            .environment(TunnelOrchestrator.bootstrap())
    }
#endif
