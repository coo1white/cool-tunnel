// Views/ContentView.swift
//
// Composition root: lays out the four main panels and wires them
// to the shared `TunnelOrchestrator` from the environment. v0.1.5.8
// changes Settings from a modal sheet into an **inline panel** —
// tapping the gear swaps the four-panel stack for the Settings
// view inside the same window, with a Back button (Cmd+W also
// works) that returns to the main view.
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
        .background { windowBackground }
        // Apply the user's appearance choice. `.system` returns
        // nil from `colorScheme`, which leaves the appearance to
        // follow `NSAppearance.current` (the macOS system
        // setting). `.light` / `.dark` lock the app regardless
        // of the system. The dynamic palette in MalteseTheme
        // resolves itself the moment this appearance changes.
        .preferredColorScheme(orchestrator.settings.appearanceMode.colorScheme)
    }

    private var mainStack: some View {
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
    }

    /// Mode-aware pastel wash: stays subtle in idle, leans into the
    /// chosen mode colour while the proxy is running. The window
    /// itself becomes a mood ring.
    ///
    /// On the `.light` performance tier (older Intel Macs) we drop
    /// the gradient overlay and the cross-fade animation — the
    /// static cream tint stays so the cards still feel framed, but
    /// the compositor doesn't have to re-blend a full-window
    /// gradient on every state change.
    private var windowBackground: some View {
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
