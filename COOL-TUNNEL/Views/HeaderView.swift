// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
// Views/HeaderView.swift
//
// **Phase 2.1 (v0.2):** rewritten as a quiet status row in the
// system idiom — semantic colour dot (red / orange / green /
// secondary) + headline + subtitle, sitting on the inherited
// `.windowBackground` material with no card around it.
//
// **Phase 2.2 (v0.2):** the firewall badge is now a real button
// that deep-links to `x-apple.systempreferences:` →
// Privacy & Security / Firewall. Pre-2.2 it was a tooltip-only
// pill with no path to resolution — the audit's "warning with
// no recourse" finding.
//
// **UX-F#1 (v0.1.7.17):** the dismissible error banner surfaces
// `lastError` with a destructive tint and an `xmark.circle.fill`
// close button. Paired with the engine-side fix that finally
// populates `lastError` on Start failure.
//
// **v2.0.8 (UI compaction):** a user screenshot showed the
// upper-middle of the window was nearly all blank — the status
// row sat on its own line above the mode picker + Start row,
// and the "Pick a mode below to connect." subtitle narrated an
// action whose UI (the segmented mode picker) was three pixels
// below it. We now render the status as a *single-line pill*
// (`HeaderStatusPill`) and let ContentView place it inline with
// the control row in a single HStack. The firewall warning is
// likewise extracted as a standalone `FirewallBadge` so it can
// sit at the trailing edge of the merged row. Net result: the
// whole title-bar area collapses from three rows of chrome
// (status + controls + spacing) down to one row, plus the
// optional error banner below.
//
//   Pre-v2.0.8 layout                v2.0.8 layout
//   ─────────────────────────       ─────────────────────────────
//   ● Not connected                 ● Not connected   [Smart…]
//     Pick a mode below…            ▶ Start  ⚕  ⏱  ⚙  [Firewall]
//   [Smart│Global│Local] [Start…]
//
// Subtitle ("Pick a mode below to connect.") is dropped
// entirely — the mode picker on the same row is the action it
// described, and "Not connected" already conveys state. When
// connected, the picker's highlighted segment shows the active
// mode, so we don't need to repeat the mode in the headline
// either.

import AppKit
import SwiftUI
import os

/// Top-level view that hosts the dismissible error banner.
///
/// The status pill and firewall badge moved out as standalone
/// views (`HeaderStatusPill`, `FirewallBadge`) so the parent
/// (ContentView) can place them inline with the control row in
/// a single horizontal layout. HeaderView is now responsible
/// for nothing but the error-banner job — it renders an empty
/// stack when there's no error, and the destructive-tinted row
/// when `lastError` is non-nil.
public struct HeaderView: View {
    public let lastError: String?
    public let onDismissError: () -> Void

    public init(
        lastError: String?,
        onDismissError: @escaping () -> Void
    ) {
        self.lastError = lastError
        self.onDismissError = onDismissError
    }

    public var body: some View {
        if let lastError, !lastError.isEmpty {
            errorBanner(message: lastError)
        }
    }

    // MARK: - Error banner

    /// Inline, dismissible error banner. Renders below the
    /// merged status/controls row when `lastError` is non-nil.
    /// Uses the system `.red` accent through `.background` /
    /// `.foregroundStyle` so the banner picks up Increased
    /// Contrast and accessibility preferences for free.
    private func errorBanner(message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.white)
                .padding(.top, 1)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .foregroundStyle(.white)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button {
                onDismissError()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss error")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.red, in: .rect(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: \(message). Double-tap to dismiss.")
    }
}

// MARK: - Standalone status pill

/// Compact single-line status pill — semantic colour dot +
/// headline ("Not connected" / "Connected" / "Error"). Designed
/// to sit inline with the control row at the top of the window.
///
/// **v2.0.8:** dropped the two-line VStack (headline +
/// subtitle) the v0.2 audit shipped. The subtitle was either
/// instructional (the mode picker right next to it is the
/// action) or redundant with the mode picker's own visible
/// selection — pure vertical waste.
public struct HeaderStatusPill: View {
    public let isRunning: Bool
    public let lastError: String?

    public init(isRunning: Bool, lastError: String?) {
        self.isRunning = isRunning
        self.lastError = lastError
    }

    public var body: some View {
        HStack(spacing: 8) {
            statusDot
            Text(headline)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(headline)
    }

    /// Colour + shape redundancy: the status is communicated by
    /// both the dot's tint AND the surrounding text, so users
    /// with red-green colour blindness still read state
    /// correctly. Same pattern Wi-Fi and Bluetooth menus use.
    private var statusDot: some View {
        Circle()
            .fill(statusTint)
            .frame(width: 10, height: 10)
            .accessibilityHidden(true)
    }

    private var statusTint: Color {
        if lastError != nil { return .red }
        if isRunning { return .green }
        return .secondary
    }

    private var headline: String {
        if lastError != nil { return "Error" }
        if isRunning { return "Connected" }
        return "Not connected"
    }
}

// MARK: - Standalone firewall badge

/// Compact warning badge — a Button that deep-links to System
/// Settings → Privacy & Security → Firewall via the
/// `x-apple.systempreferences:` URL scheme. Caller decides
/// whether to render it (typically gated on
/// `firewallState == .enabled`).
///
/// **Phase 2.2 (v0.2):** closes the audit's "warning with no
/// recourse" finding — clicking the badge takes the user one
/// hop from the actual fix, the same way Apple's own apps hand
/// off to System Settings panes.
///
/// **v2.0.8:** extracted from HeaderView so the parent can
/// place it at the trailing edge of the merged status/controls
/// row, instead of forcing a separate header row just to host
/// it.
public struct FirewallBadge: View {
    public init() {}

    public var body: some View {
        Button {
            Self.openFirewallPane()
        } label: {
            Label("Firewall on", systemImage: "exclamationmark.shield")
                .font(.caption)
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.orange.opacity(0.12), in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        // `.pointerStyle(.link)` would be the right cursor hint
        // here but it's macOS 15+. The deployment target is 14,
        // so we lean on `.help(...)` + button affordance instead;
        // the capsule background change on hover (system-default
        // for `.buttonStyle(.plain)` over an interactive surface)
        // gives the click affordance.
        .help(
            "The macOS Application Firewall is on. Click to open Privacy & Security in System Settings — outbound traffic to your proxy may be blocked until you allow it there."
        )
        .accessibilityLabel("Firewall is on. Open Privacy & Security in System Settings.")
        .accessibilityHint(
            "Opens System Settings to the Firewall pane so you can allow Cool Tunnel through the Application Firewall."
        )
        .accessibilityAddTraits(.isButton)
    }

    /// Opens the macOS Privacy & Security pane (where the
    /// Application Firewall lives in macOS 13+). Tries the
    /// canonical pane URL first; if that fails (a future macOS
    /// renames the pane), falls back to the bare
    /// `x-apple.systempreferences:` root which always opens
    /// System Settings to its sidebar so the user can navigate
    /// manually. We never block the user behind a click that
    /// silently does nothing.
    @MainActor
    private static func openFirewallPane() {
        let primary = URL(string: "x-apple.systempreferences:com.apple.preference.security?Firewall")!
        if NSWorkspace.shared.open(primary) {
            Self.uiLogger.info("opened Firewall pane via primary URL")
            return
        }
        let fallback = URL(string: "x-apple.systempreferences:")!
        if NSWorkspace.shared.open(fallback) {
            Self.uiLogger.notice(
                "Firewall pane URL failed; opened System Settings root as fallback"
            )
            return
        }
        Self.uiLogger.error(
            "could not open System Settings — both URLs failed"
        )
    }

    /// Subsystem-scoped logger for the header-view surface.
    /// Same `subsystem == "space.coolwhite.cooltunnel"` umbrella
    /// the rest of the UI uses.
    private static let uiLogger = Logger.cooltunnel("UI.Header")
}
