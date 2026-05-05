// Views/MenuBarStatusContent.swift
//
// **MenuBar-F#1 (v0.2):** primary control surface for the proxy use
// case. The menu bar is where Mac proxy users *expect* state and
// quick toggles — see the v0.2 audit. Before this file the only way
// to switch modes or stop the proxy was to focus the main window.
//
// **Phase 2.0 Menu Layout (v0.2):** flattened from the original
// "Start + Mode › submenu" pair into inline mode rows so each
// mode is one click, not two. Three redundant click-paths
// collapse into one: clicking "Smart" starts in Smart (when
// stopped) or hot-swaps to Smart (when running) — same single
// `switchMode(.smart)` call either way. The original "Start
// <last-used-mode>" button was strictly redundant with the
// mode-row click and got cut.
//
// Layout (top-down, fixed order — never reorder mid-session):
//
//   <status header — non-selectable Section header>
//   Smart                   (✓ when active)
//   Global                  (✓ when active)
//   Local                   (✓ when active)
//   ── divider ──           (only when running)
//   Stop                    (only when running) ⌘⇧L
//   ── divider ──
//   Open Cool Tunnel        ⌘0
//   Settings…               ⌘,
//   ── divider ──
//   Quit Cool Tunnel        ⌘Q
//
// The header is rendered as a SwiftUI `Section(headerString)`; the
// `MenuBarExtra(.menu)` style turns Section headers into a non-
// selectable grey label, which is exactly the right rendering for a
// "current state" line that the user reads but does not click.
//
// The view reads the orchestrator from the environment — the same
// instance the main window uses — so toggling a mode from the menu
// bar updates the window's status pill and vice-versa with no
// extra plumbing.

import SwiftUI
import AppKit
import os

@MainActor
struct MenuBarStatusContent: View {
    @Environment(TunnelOrchestrator.self) private var orchestrator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            // Status header + inline mode rows.
            //
            // **Phase 2.0 (v0.2):** Section(headerText) renders as a
            // non-selectable grey label, identical to the
            // Wi-Fi / AirPort menu's "Networks" header. The
            // three mode rows live inside this section so they
            // visually associate with the status they govern.
            Section(statusLine) {
                modeRow(.smart, label: "Smart")
                modeRow(.global, label: "Global")
                modeRow(.localOnly, label: "Local")
            }

            // Stop is the only way the menu can affect a running
            // proxy without changing mode. It only appears when
            // there is something to stop — a stopped menu has
            // three clear actions (the modes), no dead button.
            if orchestrator.isRunning {
                Divider()
                Button("Stop") {
                    Task {
                        do {
                            try await orchestrator.switchMode(to: .stopped)
                        } catch {
                            Self.uiLogger.error(
                                "menu-bar Stop failed: \(error.localizedDescription, privacy: .public)"
                            )
                        }
                    }
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }

            Divider()

            Button("Open Cool Tunnel") {
                openMainWindow()
            }
            .keyboardShortcut("0", modifiers: .command)

            Button("Settings…") {
                openMainWindow()
                NotificationCenter.default.post(
                    name: .openCoolTunnelSettings, object: nil)
            }
            .keyboardShortcut(",", modifiers: .command)

            Divider()

            Button("Quit Cool Tunnel") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }

    // MARK: - Status line

    /// Single string used by both the menu-bar header *and* the main
    /// window's HeaderView subtitle should ever consume. If we add
    /// more surfaces later (notifications, Today widgets, Shortcuts
    /// app), they read this same descriptor — two surfaces never
    /// disagree about state.
    private var statusLine: String {
        if let error = orchestrator.lastError, !error.isEmpty {
            return "Error · \(error)"
        }
        if orchestrator.isRunning {
            return "Active · \(orchestrator.activeMode.title)"
        }
        return "Idle"
    }

    // MARK: - Mode rows

    /// Renders one inline mode row. Click semantics:
    ///   - stopped → starts in `mode`
    ///   - running in another mode → hot-swaps to `mode`
    ///   - running in `mode` already → no-op (orchestrator
    ///     short-circuits matching mode in `switchMode`)
    /// All three converge on the same `switchMode(to:)` call,
    /// so the orchestrator's `transitionInFlight` guard
    /// (Engine-F#P1.3) covers menu-bar / window races.
    /// Disabled when no profile is available — without one
    /// the engine can't start, and clicking would surface a
    /// "no profile selected" error from the new P0 #1 path.
    @ViewBuilder
    private func modeRow(_ mode: ProxyMode, label: String) -> some View {
        let isActive = orchestrator.isRunning && orchestrator.activeMode == mode
        Button {
            Task {
                do {
                    try await orchestrator.switchMode(to: mode)
                } catch {
                    // **Engine-F#P2.4 (v0.2):** the orchestrator's
                    // `startCore` now publishes the failure to
                    // `lastError` before re-throwing, so the
                    // status banner already reflects it. We log a
                    // structured trace for support diagnostics —
                    // empty catches were eating context that
                    // bug reports need.
                    Self.uiLogger.error(
                        "menu-bar mode switch to \(mode.title, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        } label: {
            // Leading checkmark mirrors the AirPort menu's
            // "✓ network-name" pattern — system users read it
            // without thinking. SwiftUI `Label` + `.titleAndIcon`
            // keeps the icon column aligned with un-checked rows
            // (where we render plain `Text`) so labels don't
            // jitter sideways when state changes.
            if isActive {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
        .disabled(orchestrator.selectedProfile == nil)
    }

    /// **Engine-F#P2.4 (v0.2):** project-wide UI logger. Empty
    /// catches were dropping every "Start failed" trace before
    /// support could see it; routing through `Logger.cooltunnel`
    /// puts these failures under the same subsystem as
    /// CoreClient / Orchestrator so a single `log show
    /// --predicate 'subsystem == "space.coolwhite.cooltunnel"'`
    /// captures the full picture.
    private static let uiLogger = Logger.cooltunnel("UI.MenuBar")

    /// Bring the single main window to front. AppKit's reopen path
    /// already handles "no visible windows" via the AppDelegate's
    /// `applicationShouldHandleReopen` — we mimic that here so the
    /// menu-bar entry point is a peer of dock-icon click.
    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let main = NSApp.windows.first(where: {
            $0.identifier?.rawValue == WindowID.main
        }) {
            main.makeKeyAndOrderFront(nil)
        } else {
            // Fallback for the (rare) case where the Window scene
            // hasn't materialised yet — opens the scene by id.
            openWindow(id: WindowID.main)
        }
    }
}
