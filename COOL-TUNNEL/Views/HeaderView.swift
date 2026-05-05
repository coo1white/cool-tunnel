// Views/HeaderView.swift
//
// **Phase 2.1 (v0.2):** rewritten as a quiet status row in the
// system idiom — semantic colour dot (red / orange / green /
// secondary) + headline + subtitle, sitting on the inherited
// `.windowBackground` material with no card around it.
//
// Earlier versions wrapped the same information in a pastel
// gradient card with an animated `shippingbox` glyph and a
// gradient `COOL TUNNEL` brand mark. The v2.0 audit flagged that
// as the loudest "doesn't look like a Mac app" surface. The
// status itself was already clear; the chrome around it was the
// problem.
//
// **Phase 2.2 (v0.2):** the firewall badge is now a real button
// that deep-links to `x-apple.systempreferences:` →
// Privacy & Security / Firewall. Pre-2.2 it was a tooltip-only
// pill with no path to resolution — the audit's "warning with
// no recourse" finding. Tapping it now sends the user one click
// from the actual fix, the same way Apple's own apps hand off
// to System Settings panes.
//
// **UX-F#1 (v0.1.7.17):** the dismissible error banner is
// preserved — `lastError` still surfaces here as an inline row
// with destructive tint and an `xmark.circle.fill` close button.
// The banner is the user's main signal that an engine error
// occurred (paired with the new Engine-F#P0 fix that finally
// populates `lastError` on Start failure).

import AppKit
import SwiftUI
import os

/// Status row at the top of the main window. Inputs are plain
/// values rather than the full orchestrator so the view stays
/// cheap to re-render and trivially previewable.
public struct HeaderView: View {
    public let isRunning: Bool
    public let activeMode: ProxyMode
    public let firewallState: FirewallState
    public let lastError: String?
    public let onDismissError: () -> Void

    public init(
        isRunning: Bool,
        activeMode: ProxyMode,
        firewallState: FirewallState,
        lastError: String?,
        onDismissError: @escaping () -> Void
    ) {
        self.isRunning = isRunning
        self.activeMode = activeMode
        self.firewallState = firewallState
        self.lastError = lastError
        self.onDismissError = onDismissError
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusRow
            if let lastError, !lastError.isEmpty {
                errorBanner(message: lastError)
            }
        }
    }

    // MARK: - Status row

    private var statusRow: some View {
        HStack(alignment: .center, spacing: 10) {
            statusDot
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if firewallState == .enabled {
                firewallBadge
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(headline). \(subtitle).")
    }

    /// Colour + shape redundancy: the status is communicated by
    /// both the dot's tint AND the surrounding text, so users with
    /// red-green colour blindness still read state correctly.
    /// Filled vs. outlined is also implicit in the system colour
    /// (red error / green active / muted idle), which is the
    /// same pattern Wi-Fi and Bluetooth menus use.
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

    private var subtitle: String {
        if isRunning {
            return activeMode.title
        }
        return "Pick a mode below to connect."
    }

    // MARK: - Firewall badge

    /// Compact warning badge — a Button that deep-links to
    /// System Settings → Privacy & Security → Firewall via the
    /// `x-apple.systempreferences:` URL scheme. Phase 2.2 closes
    /// the audit's "warning with no recourse" finding: clicking
    /// the badge takes the user one hop from the actual fix.
    /// `.buttonStyle(.plain)` keeps the visual identical to the
    /// pre-2.2 capsule so existing users don't have to relearn
    /// what the indicator means.
    private var firewallBadge: some View {
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
        .help("The macOS Application Firewall is on. Click to open Privacy & Security in System Settings — outbound traffic to your proxy may be blocked until you allow it there.")
        .accessibilityLabel("Firewall is on. Open Privacy & Security in System Settings.")
        .accessibilityHint("Opens System Settings to the Firewall pane so you can allow Cool Tunnel through the Application Firewall.")
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
    /// the rest of the UI uses, so a single `log show` predicate
    /// captures the deep-link handoff alongside engine /
    /// orchestrator traces.
    private static let uiLogger = Logger.cooltunnel("UI.Header")

    // MARK: - Error banner

    /// Inline, dismissible error banner. Renders below the
    /// status row when `lastError` is non-nil. Uses the system
    /// `.red` accent through `.background`/`.foregroundStyle` so
    /// the banner picks up Increased Contrast and accessibility
    /// preferences for free.
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
