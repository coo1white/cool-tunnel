// Views/HeaderView.swift
//
// Title bar redesigned for the v0.1.5.4 visual refresh: app icon on
// a pastel gradient card, animated status pill that bounces on
// state-change, inline firewall warning. Pulls all colours from
// `CTPalette` so the look stays consistent with the mode picker.

import SwiftUI

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
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [CTPalette.inkBlue, CTPalette.cherryRose],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }

            Spacer()

            statusPill

            if firewallState == .enabled {
                firewallBadge
            }
        }
        .padding(14)
        .pupCard(cornerRadius: 22, tint: CTPalette.accent(for: activeMode))
    }

    private var subtitle: String {
        isRunning ? "Active · \(activeMode.title)" : "Idle · ready when you are"
    }

    /// Status pill — pastel gradient when active, soft material when
    /// idle. Reads the same accent the icon uses so the two surfaces
    /// move together when the mode changes.
    private var statusPill: some View {
        let tint = CTPalette.accent(for: activeMode)
        return HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
                .shadow(color: tint.opacity(0.6), radius: 4)
                // Pulse the live-status dot while running so the
                // header has a heartbeat. Flat circle when idle.
                .symbolEffect(.pulse, options: .repeating, isActive: isRunning)
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
        .animation(.spring(response: 0.32, dampingFraction: 0.72), value: activeMode)
    }

    private var firewallBadge: some View {
        Label(firewallState.description, systemImage: "exclamationmark.shield.fill")
            .font(.caption.weight(.medium))
            .foregroundStyle(CTPalette.cherryRose)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                Capsule(style: .continuous).fill(CTPalette.bunnyPink.opacity(0.20))
            }
            .overlay {
                Capsule(style: .continuous).strokeBorder(CTPalette.cherryRose.opacity(0.4), lineWidth: 0.6)
            }
    }
}
