// Views/HeaderView.swift
//
// Title bar: app name, status pill, and an inline firewall warning when the
// macOS Application Firewall is enabled.

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
            Image(systemName: "shippingbox.and.arrow.backward.fill")
                .font(.system(size: 32))
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text("COOL TUNNEL")
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            statusPill

            if firewallState == .enabled {
                firewallBadge
            }
        }
    }

    private var subtitle: String {
        isRunning ? "Active · \(activeMode.title)" : "Idle"
    }

    private var statusPill: some View {
        Text(activeMode.title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(pillColor.opacity(0.18))
            )
            .overlay(
                Capsule().stroke(pillColor, lineWidth: 1)
            )
            .foregroundStyle(pillColor)
    }

    private var pillColor: Color {
        switch activeMode {
        case .stopped: .secondary
        case .smart: .blue
        case .global: .orange
        case .localOnly: .green
        }
    }

    private var firewallBadge: some View {
        Label(firewallState.description, systemImage: "exclamationmark.shield")
            .font(.caption)
            .foregroundStyle(.orange)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.orange.opacity(0.12))
            )
    }
}
