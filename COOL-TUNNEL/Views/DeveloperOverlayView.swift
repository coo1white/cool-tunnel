// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
// Views/DeveloperOverlayView.swift

import SwiftUI

/// Non-intrusive operator HUD for live tunnel internals.
public struct DeveloperOverlayView: View {
    public let metrics: DeveloperMetrics

    public init(metrics: DeveloperMetrics) {
        self.metrics = metrics
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Developer Overlay")
                    .font(.headline)
                Spacer()
                Text(sampleText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                metricTile(
                    title: "Throughput",
                    value: "\(formatBytes(metrics.throughput.inboundBytesPerSecond))/s down",
                    detail:
                        "\(formatBytes(metrics.throughput.outboundBytesPerSecond))/s up · \(metrics.throughput.status)",
                    systemImage: "arrow.up.arrow.down"
                )
                metricTile(
                    title: "Encryption",
                    value: metrics.encryption.overheadMs.map(formatMs) ?? "Waiting",
                    detail: encryptionDetail,
                    systemImage: "lock.shield"
                )
                metricTile(
                    title: "VPS",
                    value: vpsValue,
                    detail: vpsDetail,
                    systemImage: "server.rack"
                )
                metricTile(
                    title: "Local Kernel",
                    value: kernelValue,
                    detail: metrics.localKernel.status,
                    systemImage: "cpu"
                )
            }
        }
        .padding(12)
        .frame(maxWidth: 780)
        .background(.thinMaterial, in: .rect(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
    }

    private func metricTile(
        title: String,
        value: String,
        detail: String,
        systemImage: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(.callout, design: .monospaced).weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(9)
        // `width` is fixed so the four tiles align as a strict
        // column row; height is `minHeight` so an unusually long
        // status string (`metrics.vps.status` after a probe error,
        // for instance) grows the tile instead of being clipped
        // by the previous rigid `height: 86`. All four tiles in a
        // row visually equalise to the tallest because the HStack
        // resolves their heights together.
        .frame(width: 178, alignment: .topLeading)
        .frame(minHeight: 86, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value). \(detail)")
    }

    private var sampleText: String {
        guard let sampledAt = metrics.sampledAt else { return "No sample" }
        return sampledAt.formatted(date: .omitted, time: .standard)
    }

    private var encryptionDetail: String {
        guard
            let direct = metrics.encryption.directHandshakeMs,
            let proxied = metrics.encryption.proxiedHandshakeMs
        else {
            return metrics.encryption.status
        }
        return "TLS direct \(formatMs(direct)) · proxy \(formatMs(proxied))"
    }

    private var vpsValue: String {
        switch metrics.vps.reachable {
        case .some(true): "Reachable"
        case .some(false):
            if metrics.vps.dnsMs == nil, metrics.vps.tcpMs == nil {
                "Probe error"
            } else {
                "Blocked"
            }
        case .none: "Checking"
        }
    }

    private var vpsDetail: String {
        if metrics.vps.reachable == false,
            metrics.vps.dnsMs == nil,
            metrics.vps.tcpMs == nil,
            !metrics.vps.status.isEmpty
        {
            return "\(metrics.vps.server) · \(metrics.vps.status)"
        }
        let dns = metrics.vps.dnsMs.map { "DNS \(formatMs($0))" } ?? "DNS ?"
        let tcp = metrics.vps.tcpMs.map { "TCP \(formatMs($0))" } ?? "TCP ?"
        return "\(metrics.vps.server) · \(dns) · \(tcp)"
    }

    private var kernelValue: String {
        if metrics.localKernel.naiveRunning == true {
            return metrics.localKernel.pid.map { "PID \($0)" } ?? "Running"
        }
        if metrics.localKernel.naiveRunning == false {
            return "Stopped"
        }
        return "Unknown"
    }

    private func formatBytes(_ bytes: Int) -> String {
        let value = Double(max(0, bytes))
        if value >= 1_048_576 {
            return String(format: "%.1f MB", value / 1_048_576.0)
        }
        if value >= 1024 {
            return String(format: "%.1f KB", value / 1024.0)
        }
        return "\(Int(value)) B"
    }

    private func formatMs(_ ms: Double) -> String {
        guard ms.isFinite, ms >= 0 else { return "?" }
        if ms >= 1000 {
            return String(format: "%.2fs", ms / 1000.0)
        }
        return "\(Int(ms.rounded()))ms"
    }
}
