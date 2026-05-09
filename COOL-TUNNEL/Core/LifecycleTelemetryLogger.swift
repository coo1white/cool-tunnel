// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
// Core/LifecycleTelemetryLogger.swift
//
// Local, append-only lifecycle telemetry for operator support.

import Darwin
import Foundation
import os

/// File-backed JSONL logger for tunnel lifecycle transitions.
///
/// Every row carries both wall-clock microseconds (`epoch_us`) and
/// monotonic process-uptime microseconds (`uptime_us`). Wall-clock
/// fields make support transcripts easy to correlate with Console.app;
/// monotonic fields make transition ordering deterministic even if NTP
/// adjusts the system clock mid-session.
public final class LifecycleTelemetryLogger: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "space.coolwhite.cooltunnel.lifecycle-telemetry")
    private let bootNanos = DispatchTime.now().uptimeNanoseconds
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    public init(url: URL) {
        self.url = url
        ensureFileExists()
    }

    public func record(
        _ event: String,
        mode: ProxyMode?,
        running: Bool,
        layer: ErrorLayer? = nil,
        message: String? = nil,
        details: [String: String] = [:]
    ) {
        let now = Date()
        let uptimeNanos = DispatchTime.now().uptimeNanoseconds &- bootNanos
        let record = LifecycleTelemetryRecord(
            epochUs: Self.epochMicroseconds(now),
            uptimeUs: uptimeNanos / 1_000,
            timestamp: Self.timestamp(now),
            event: event,
            mode: mode?.rawValue,
            running: running,
            layer: layer?.diagnosticLabel,
            message: message.map(Self.redact),
            details: details.mapValues(Self.redact)
        )

        queue.sync { [url, encoder] in
            do {
                let parent = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(
                    at: parent,
                    withIntermediateDirectories: true
                )
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(
                        atPath: url.path,
                        contents: nil,
                        attributes: [.posixPermissions: 0o600]
                    )
                }
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: url.path
                )
                var data = try encoder.encode(record)
                data.append(0x0A)
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                Self.logger.error(
                    "lifecycle telemetry append failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func ensureFileExists() {
        queue.sync { [url] in
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(
                        atPath: url.path,
                        contents: nil,
                        attributes: [.posixPermissions: 0o600]
                    )
                }
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: url.path
                )
            } catch {
                Self.logger.error(
                    "lifecycle telemetry setup failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private static func epochMicroseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000_000.0).rounded())
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func redact(_ raw: String) -> String {
        raw.replacingOccurrences(
            of: #"([a-zA-Z][a-zA-Z0-9+.\-]*://)[^/\s:@]+:[^@\s/]+@"#,
            with: "$1***:***@",
            options: .regularExpression
        )
    }

    private static let logger = Logger.cooltunnel("LifecycleTelemetry")
}

private struct LifecycleTelemetryRecord: Encodable {
    let schemaVersion: UInt8 = 1
    let epochUs: Int64
    let uptimeUs: UInt64
    let timestamp: String
    let event: String
    let mode: String?
    let running: Bool
    let layer: String?
    let message: String?
    let details: [String: String]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case epochUs = "epoch_us"
        case uptimeUs = "uptime_us"
        case timestamp
        case event
        case mode
        case running
        case layer
        case message
        case details
    }
}
