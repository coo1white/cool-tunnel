// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
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

import AppKit
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
        // **v2.0.8 (appearance scroll-position fix):**
        // appearance is now driven through `NSApp.appearance`
        // (AppKit-level) rather than SwiftUI's
        // `.preferredColorScheme(_:)`. The previous v2.0.5
        // implementation used `conditionallyPreferredColorScheme`
        // which had an `if let scheme { … } else { self }`
        // branch — every appearance change toggled the view
        // structure, and SwiftUI invalidated the entire ZStack
        // subtree. The SettingsView's ScrollView lost its
        // scroll position on every Match System / Light / Dark
        // tap, dumping the user back to the top. AppKit-level
        // appearance propagates via `NSWindow.effectiveAppearance`
        // without changing any SwiftUI view structure, so the
        // ScrollView stays put and only the resolved colours
        // update. We apply the persisted preference once on
        // appear and then on every subsequent change.
        .task(id: orchestrator.settings.appearanceMode) {
            Self.applyAppearance(orchestrator.settings.appearanceMode)
        }
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

    /// **v2.0.8:** apply an AppearanceMode at the AppKit level
    /// by setting `NSApp.appearance`. Cocoa propagates the
    /// resolved appearance to every NSWindow (including the
    /// SwiftUI-hosted ones), and SwiftUI picks up the change
    /// through `NSWindow.effectiveAppearance` without rebuilding
    /// the view tree.
    ///
    /// `nil` (the `.system` case) clears the override so the
    /// app follows the system appearance — the AppKit-native
    /// way of saying "Match System." This is what the v2.0.5
    /// SwiftUI workaround was trying to do, only without the
    /// view-structure thrash that caused the Settings scroll
    /// position to reset on every change (the bug a user
    /// reported between v2.0.7 and v2.0.8).
    @MainActor
    private static func applyAppearance(_ mode: AppearanceMode) {
        let appearance: NSAppearance?
        switch mode {
        case .system: appearance = nil
        case .light: appearance = NSAppearance(named: .aqua)
        case .dark: appearance = NSAppearance(named: .darkAqua)
        }
        NSApp.appearance = appearance
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
            // --- Top pane: merged header row + form ---
            VStack(spacing: 0) {
                // **v2.0.8 (UI compaction):** the header status
                // and the controls row used to be two separate
                // rows — `HeaderView` (dot + 2-line headline +
                // firewall pill, with a subtitle that just
                // narrated the action whose UI was three pixels
                // below it) above `ControlPanelView` (mode
                // picker + Start + buttons). A user screenshot
                // showed the upper-middle of the window was
                // nearly all blank.
                //
                // We now place all of it on a single row:
                //
                //   ●  Not connected  ────  [Smart│Global│Local]
                //   ▶ Start  ⚕  ⏱⌄  ⚙  [⚠ Firewall on]
                //
                // The subtitle is dropped (the mode picker on
                // the same row IS what it was instructing the
                // user to do). The firewall badge moves to the
                // far trailing edge so it doesn't fight the
                // primary action for visual weight. Net win:
                // the title-bar area collapses from three rows
                // of chrome to one, plus the optional error
                // banner below.
                mergedHeaderRow

                // Error banner under the merged row when an
                // engine error is live. HeaderView is now
                // exclusively responsible for this surface;
                // when there's no error its body is an empty
                // view and contributes zero height.
                HeaderView(
                    lastError: orchestrator.lastError,
                    lastErrorLayer: orchestrator.lastErrorLayer,
                    onDismissError: { orchestrator.dismissLastError() }
                )
                .padding(.horizontal, 20)
                .padding(.bottom, orchestrator.lastError == nil ? 0 : 8)

                ConnectionFormView()
            }
            // Preserve enough vertical room for the merged row
            // + the four Server form rows + footer text. Below
            // this minimum the form starts truncating, which the
            // user can't fix by dragging (the divider just stops).
            // **v2.0.8:** lowered from 360 → 320 because the
            // merged single-row header reclaims ~40 pt of
            // vertical space that the previous two-row layout
            // ate.
            .frame(minHeight: 320)

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

    /// **v2.0.8:** single horizontal row carrying the status
    /// pill, the mode picker, the Start/Stop button, the
    /// secondary action buttons, and the firewall warning
    /// badge — the entire upper chrome of the main window.
    ///
    /// Layout: status pill is leading, then a flexible spacer
    /// pushes the controls to centre/trailing, then the
    /// firewall badge anchors the far-right edge when present.
    /// On the macOS minimum window width (~700 pt) the picker
    /// stays comfortably above its 240-pt natural width and the
    /// firewall pill keeps its full text; if the user drags the
    /// window narrower than expected, the picker truncates
    /// before the buttons do, then the picker shrinks before
    /// the firewall pill drops its label — same priority order
    /// the system uses for toolbar items.
    private var mergedHeaderRow: some View {
        HStack(spacing: 12) {
            HeaderStatusPill(
                isRunning: orchestrator.isRunning,
                lastError: orchestrator.lastError,
                sleepWakeState: orchestrator.sleepWakeState
            )
            // Flexible gap so the status pill hugs leading and
            // the controls cluster centre-trailing. `minLength`
            // gives a real visual breathing-room floor; without
            // it the pill and picker can touch on small windows.
            Spacer(minLength: 16)

            ControlPanelView(
                isShowingSettings: $isShowingSettings
            )
            .layoutPriority(1)

            if orchestrator.firewallState == .enabled {
                FirewallBadge()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
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

// **v2.0.8:** the `conditionallyPreferredColorScheme(_:)`
// helper that v2.0.5 added is gone. Driving appearance through
// SwiftUI's `.preferredColorScheme(_:)` — even with the
// conditional `if let` workaround — caused the SettingsView's
// ScrollView to scroll back to the top on every appearance
// change, because toggling the modifier alters the view-tree
// structure and SwiftUI rebuilds the subtree. v2.0.8 sets
// `NSApp.appearance` directly from `ContentView.body.task(id:)`
// instead, so the SwiftUI tree is unchanged and only the
// resolved colours update. See `applyAppearance(_:)` in
// `ContentView`.
