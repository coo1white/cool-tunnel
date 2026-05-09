// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
// Core/DeveloperMetrics.swift

import Foundation

/// Live metrics rendered by the optional developer overlay.
public struct DeveloperMetrics: Sendable, Equatable {
    public var sampledAt: Date?
    public var throughput: Throughput
    public var encryption: EncryptionOverhead
    public var vps: VPSHealth
    public var localKernel: LocalKernelHealth

    public init(
        sampledAt: Date?,
        throughput: Throughput,
        encryption: EncryptionOverhead,
        vps: VPSHealth,
        localKernel: LocalKernelHealth
    ) {
        self.sampledAt = sampledAt
        self.throughput = throughput
        self.encryption = encryption
        self.vps = vps
        self.localKernel = localKernel
    }

    public static let idle = DeveloperMetrics(
        sampledAt: nil,
        throughput: .idle,
        encryption: .idle,
        vps: .idle,
        localKernel: .idle
    )
}

extension DeveloperMetrics {
    public struct Throughput: Sendable, Equatable {
        public var inboundBytesPerSecond: Int
        public var outboundBytesPerSecond: Int
        public var status: String

        public init(
            inboundBytesPerSecond: Int,
            outboundBytesPerSecond: Int,
            status: String
        ) {
            self.inboundBytesPerSecond = inboundBytesPerSecond
            self.outboundBytesPerSecond = outboundBytesPerSecond
            self.status = status
        }

        public static let idle = Throughput(
            inboundBytesPerSecond: 0,
            outboundBytesPerSecond: 0,
            status: "Idle"
        )
    }

    public struct EncryptionOverhead: Sendable, Equatable {
        public var directHandshakeMs: Double?
        public var proxiedHandshakeMs: Double?
        public var overheadMs: Double?
        public var status: String
        public var sampledAt: Date?

        public init(
            directHandshakeMs: Double?,
            proxiedHandshakeMs: Double?,
            overheadMs: Double?,
            status: String,
            sampledAt: Date?
        ) {
            self.directHandshakeMs = directHandshakeMs
            self.proxiedHandshakeMs = proxiedHandshakeMs
            self.overheadMs = overheadMs
            self.status = status
            self.sampledAt = sampledAt
        }

        public static let idle = EncryptionOverhead(
            directHandshakeMs: nil,
            proxiedHandshakeMs: nil,
            overheadMs: nil,
            status: "Waiting",
            sampledAt: nil
        )
    }

    public struct VPSHealth: Sendable, Equatable {
        public var server: String
        public var reachable: Bool?
        public var dnsMs: Double?
        public var tcpMs: Double?
        public var status: String
        public var checkedAt: Date?

        public init(
            server: String,
            reachable: Bool?,
            dnsMs: Double?,
            tcpMs: Double?,
            status: String,
            checkedAt: Date?
        ) {
            self.server = server
            self.reachable = reachable
            self.dnsMs = dnsMs
            self.tcpMs = tcpMs
            self.status = status
            self.checkedAt = checkedAt
        }

        public static let idle = VPSHealth(
            server: "No server",
            reachable: nil,
            dnsMs: nil,
            tcpMs: nil,
            status: "Idle",
            checkedAt: nil
        )
    }

    public struct LocalKernelHealth: Sendable, Equatable {
        public var pid: UInt32?
        public var naiveRunning: Bool?
        public var firewallState: FirewallState
        public var status: String

        public init(
            pid: UInt32?,
            naiveRunning: Bool?,
            firewallState: FirewallState,
            status: String
        ) {
            self.pid = pid
            self.naiveRunning = naiveRunning
            self.firewallState = firewallState
            self.status = status
        }

        public static let idle = LocalKernelHealth(
            pid: nil,
            naiveRunning: nil,
            firewallState: .unknown,
            status: "Idle"
        )
    }
}
