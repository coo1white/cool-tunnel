// Views/HeaderView.swift
//
// Title bar redesigned for the v0.1.5.4 visual refresh: app icon on
// a pastel gradient card, animated status pill that bounces on
// state-change, inline firewall warning. Pulls all colours from
// `CTPalette` so the look stays consistent with the mode picker.

import SwiftUI

/// Top card showing the app icon, name, current proxy mode, and
/// any firewall warning. Inputs are plain values rather than the
/// full orchestrator so the view stays cheap to re-render and
/// trivially previewable.
public struct HeaderView: View {
    public let isRunning: Bool
    public let activeMode: ProxyMode
    public let firewallState: FirewallState

    public init(isRunning: Bool, activeMode: ProxyMode, firewallState: FirewallState) {
        self.isRunning = isRunning
        self.activeMode = activeMode
        self.firewallState = firewallState
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 14) {
            // App icon on a pastel gradient circle. The gradient
            // tracks the active mode so the icon itself becomes a
            // mood indicator without a second label.
            ZStack {
                Circle()
                    .fill(CTPalette.dreamGradient(for: activeMode))
                    .frame(width: 52, height: 52)
                    .shadow(color: CTPalette.accent(for: activeMode).opacity(0.3), radius: 8, x: 0, y: 4)
                Image(systemName: isRunning ? "shippingbox.and.arrow.backward.fill" : "shippingbox.fill")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white)
                    // macOS 26 symbol effects: bounces when the run
                    // state flips so the user sees the state change
                    // in their peripheral vision.
                    .symbolEffect(.bounce, options: .speed(1.2), value: isRunning)
                    .contentTransition(.symbolEffect(.replace))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("COOL TUNNEL")
                    .font(CTTypography.title)
                    .foregroundStyle(
                        // Classic Mac blue → primary text. The
                        // second stop is `Color.primary` (not the
                        // hardcoded `bodyInk` light-mode ink) so
                        // the gradient remains legible in dark mode
                        // — `bodyInk` is a near-black RGB literal
                        // that disappears on dark backgrounds.
                        LinearGradient(
                            colors: [CTPalette.macBlue, .primary],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            statusPill

            if firewallState == .enabled {
                firewallBadge
            }
        }
        .padding(14)
        // 8pt matches the rest of the design system; the older 10pt
        // header was drift from the v0.1.5.7 platinum-theme pass.
        .pupCard(cornerRadius: 8, tint: CTPalette.accent(for: activeMode))
    }

    private var subtitle: String {
        isRunning ? "Active · \(activeMode.title)" : "Idle · ready when you are"
    }

    /// Status pill — pastel gradient when active, soft material when
    /// idle. Reads the same accent the icon uses so the two surfaces
    /// move together when the mode changes. The repeating pulse on
    /// the dot is gated by `PerformanceProfile` so older Intel Macs
    /// don't burn GPU on a continuously-animating heartbeat.
    private var statusPill: some View {
        let tint = CTPalette.accent(for: activeMode)
        let allowPulse = PerformanceProfile.current.repeatingSymbolEffectsAllowed
        let scale = PerformanceProfile.current.animationScale
        return HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
                .shadow(color: tint.opacity(0.6), radius: 4)
                .symbolEffect(.pulse, options: .repeating, isActive: isRunning && allowPulse)
            Text(activeMode.title)
                .font(.caption.weight(.bold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background {
            Capsule(style: .continuous).fill(tint.opacity(isRunning ? 0.22 : 0.12))
        }
        .overlay {
            Capsule(style: .continuous).strokeBorder(tint.opacity(0.6), lineWidth: 0.7)
        }
        .foregroundStyle(tint)
        .animation(.spring(response: 0.32 * scale, dampingFraction: 0.72), value: activeMode)
    }

    private var firewallBadge: some View {
        Label(firewallState.description, systemImage: "exclamationmark.shield.fill")
            .font(.caption.weight(.medium))
            .foregroundStyle(CTPalette.cherryRose)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                // Use the same `cherryRose` tint family as the
                // foreground/border so the badge reads as a single
                // alert colour. The previous `bunnyPink` background
                // was a holdover from the v0.1.5.4 Maltese palette
                // and disagreed with the rose stroke + ink-blue
                // window after the v0.1.5.7 theme retune.
                Capsule(style: .continuous).fill(CTPalette.cherryRose.opacity(0.12))
            }
            .overlay {
                Capsule(style: .continuous).strokeBorder(CTPalette.cherryRose.opacity(0.4), lineWidth: 0.6)
            }
    }
}
