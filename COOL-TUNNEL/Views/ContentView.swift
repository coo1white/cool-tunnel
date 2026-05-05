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
        //
        // **v2.0.5 fix:** SwiftUI's `.preferredColorScheme(nil)`
        // does NOT mean "follow system" the way the docs imply
        // on macOS — once the modifier has been applied with a
        // concrete value (`.light` or `.dark`) and then
        // re-applied with `nil`, the scheme stays locked at
        // whatever was last concrete. The user reported "Match
        // System will show black and white" — the app stayed
        // dark even when System Settings → Appearance is light.
        // Conditionally applying the modifier only when there's
        // an explicit override fixes it: in `.system` mode the
        // modifier is never attached, so SwiftUI follows the
        // window's `NSAppearance.current` dynamically.
        .conditionallyPreferredColorScheme(
            orchestrator.settings.appearanceMode.colorScheme
        )
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
        // **v2.0.6:** the four panes used to live in a single
        // `VStack`. Live log had `frame(minHeight: 220)` but no
        // upper bound, so on a tall window it ate every extra
        // pixel — the Server form's Password and Local-port rows
        // and the explanatory footer disappeared off the bottom
        // of the window with no scroll. Switched to `VSplitView`,
        // which gives the user a draggable divider between the
        // Form pane and the log: pull it down to surface the
        // hidden Server rows, pull it up to make the log bigger
        // for live-tail use. Both halves keep their own internal
        // scrolling within the user-chosen split.
        VSplitView {
            // --- Top pane: header + controls + form ---
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
            }
            // Preserve enough vertical room for header + controls
            // + the four Server form rows + footer text. Below
            // this minimum the form starts truncating, which the
            // user can't fix by dragging (the divider just stops).
            .frame(minHeight: 360)

            // --- Bottom pane: live log ---
            LogConsoleView()
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                .padding(.top, 8)
                // Live log can shrink to a single row at the
                // bottom (collapsing it almost-but-not-quite to
                // nothing keeps the header + Filter + actions
                // accessible). Caps at the natural max so it
                // doesn't grow past the window.
                .frame(minHeight: 80, idealHeight: 220)
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

extension View {
    /// **v2.0.5 fix:** apply `.preferredColorScheme(_:)` only
    /// when the caller has a concrete `.light` or `.dark`
    /// override. Passing `nil` to `.preferredColorScheme(_:)`
    /// directly does not actually free the view to follow
    /// system appearance — once SwiftUI has seen a concrete
    /// scheme, re-applying with `nil` leaves the scheme
    /// locked at the last value. Conditionally NOT applying
    /// the modifier (this helper) is the correct way to
    /// say "follow system."
    @ViewBuilder
    fileprivate func conditionallyPreferredColorScheme(
        _ scheme: ColorScheme?
    ) -> some View {
        if let scheme {
            self.preferredColorScheme(scheme)
        } else {
            self
        }
    }
}
