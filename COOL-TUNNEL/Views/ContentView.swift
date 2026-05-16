// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.

import AppKit
import SwiftUI

public struct ContentView: View {
    @Environment(TunnelOrchestrator.self) private var orchestrator
    @State private var isShowingSettings = false
    @State private var isShowingDeveloperOverlay = false
    /// Local draft state owned by SwiftUI; folded into
    /// `CoolTunnelUIState` before rendering so the screen still
    /// has one explicit schema.
    @State private var pendingMode: ProxyMode = .smart

    public init() {}

    public var body: some View {
        let state = viewState
        ZStack {
            // Main stack always rendered underneath so the window
            // background animation is continuous across panel swaps.
            mainStack(state: state)
                .opacity(state.ui.isShowingSettings ? 0 : 1)
                .allowsHitTesting(!state.ui.isShowingSettings)

            if state.ui.isShowingSettings {
                SettingsView(isShowing: $isShowingSettings)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            if isShowingDeveloperOverlay && !state.ui.isShowingSettings {
                VStack {
                    Spacer()
                    DeveloperOverlayView(metrics: state.developer.metrics)
                        .padding(.bottom, 18)
                }
                .padding(.horizontal, 18)
                .allowsHitTesting(false)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(2)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isShowingSettings)
        .animation(.easeInOut(duration: 0.18), value: isShowingDeveloperOverlay)
        // Appearance driven through AppKit-level `NSApp.appearance`
        // rather than SwiftUI's `.preferredColorScheme(_:)`: the
        // SwiftUI form toggles view structure and invalidates the
        // ZStack subtree, resetting SettingsView's ScrollView
        // position on every appearance change.
        .task(id: orchestrator.settings.appearanceMode) {
            Self.applyAppearance(orchestrator.settings.appearanceMode)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .openCoolTunnelSettings)
        ) { _ in
            isShowingSettings = true
        }
    }

    /// Single SwiftUI-facing schema for this render pass.
    /// Every child view below renders from this value and emits
    /// `TunnelIntent`; operational side effects stay in the
    /// orchestrator.
    private var viewState: CoolTunnelViewState {
        orchestrator.viewState(
            ui: CoolTunnelUIState(
                isShowingSettings: isShowingSettings,
                pendingMode: pendingMode
            )
        )
    }

    private func send(_ intent: TunnelIntent) {
        Task { await orchestrator.perform(intent) }
    }

    /// Applies an AppearanceMode at the AppKit level. `nil`
    /// (the `.system` case) clears the override so the app
    /// follows the system appearance.
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

    private func mainStack(state: CoolTunnelViewState) -> some View {
        // VSplitView (not VStack) so the user can drag the divider
        // to surface hidden Server form rows or grow the log for
        // live-tail. Both halves keep their own internal scrolling.
        VSplitView {
            VStack(spacing: 0) {
                mergedHeaderRow(state: state)

                HeaderView(
                    state: state.header,
                    onIntent: send
                )
                .padding(.horizontal, 20)
                .padding(.bottom, state.header.errorBanner == nil ? 0 : 8)

                ConnectionFormView()
            }
            // Minimum vertical room for the merged row + four
            // Server form rows + footer; below this the form
            // truncates and the divider stops.
            .frame(minHeight: 320)

            LogConsoleView(onIntent: send)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                .padding(.top, 8)
                .frame(minHeight: 80, idealHeight: 220)
        }
    }

    private func mergedHeaderRow(state: CoolTunnelViewState) -> some View {
        HStack(spacing: 12) {
            HeaderStatusPill(
                state: state.header.statusPill
            )
            // `minLength` gives a real breathing-room floor;
            // without it the pill and picker touch on small windows.
            Spacer(minLength: 16)

            ControlPanelView(
                state: state.controlPanel,
                pendingMode: $pendingMode,
                isShowingSettings: $isShowingSettings,
                isShowingDeveloperOverlay: $isShowingDeveloperOverlay,
                onIntent: send
            )
            .layoutPriority(1)

            if state.header.showsFirewallBadge {
                FirewallBadge()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }
}
