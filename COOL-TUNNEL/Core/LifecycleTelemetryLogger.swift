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

    /// Credential-redaction pass applied to every `message` and
    /// every `details` value before the record reaches disk. The
    /// rules match the Rust-side `cool_tunnel_core::redaction::redact`
    /// surface so a string the Rust engine already redacted stays
    /// redacted on the Swift side too, AND so a string that
    /// arrives only via Swift (e.g. a `URLError.localizedDescription`
    /// that wrapped a userinfo-bearing URL, or a Foundation error
    /// embedding an `Authorization:` header from a misbehaving
    /// reverse proxy) still gets stripped before it reaches the
    /// 0600-mode telemetry file.
    ///
    /// **W1 (v2.0.42):** pre-fix this only handled
    /// `scheme://user:pass@host`. Authorization headers, Cookie
    /// headers, JSON-shaped `"password":"…"` payloads, and
    /// multi-`@` userinfo (`https://user:p@ssword@host`) reached
    /// the file verbatim. Aligning with the Rust regex set closes
    /// the defense-in-depth gap.
    static func redact(_ raw: String) -> String {
        var current = raw
        for rule in Self.redactionRules {
            current = rule.regex.stringByReplacingMatches(
                in: current,
                range: NSRange(current.startIndex..., in: current),
                withTemplate: rule.template
            )
        }
        return current
    }

    /// `scheme://userinfo@` matcher. Greedy userinfo class
    /// `[^/\s]+@` redacts the *whole* userinfo run, so passwords
    /// containing an embedded `@` (`user:p@ssword@host`) are fully
    /// stripped rather than leaving the tail visible. Schemes
    /// matched case-insensitively to catch curl's occasional
    /// upper-cased error output.
    private static let userinfoPattern =
        #"(?i)((?:https?|socks(?:5h?|4a?)?|ftp|naive)://)[^/\s]+@"#

    /// `Authorization: <scheme> <value>` and `Proxy-Authorization:`
    /// variants. Scheme stays (Bearer / Basic / Digest is useful
    /// operator context); value is masked.
    private static let authHeaderPattern =
        #"(?i)((?:Proxy-)?Authorization:\s*[A-Za-z]+\s+)\S+"#

    /// `Cookie: …` and `Set-Cookie: …`. Whole value redacted —
    /// session tokens are conservatively all-or-nothing.
    private static let cookieHeaderPattern = #"(?i)((?:Set-)?Cookie:\s*)[^\r\n]+"#

    /// Strict-JSON quoted credential values
    /// (`"password":"Tr0ub4dor 3 cat-pic"`). Value consumes any
    /// non-`"` char or escaped pair, terminating at the literal
    /// closing quote — passwords with embedded spaces, commas, or
    /// punctuation are fully redacted.
    private static let jsonQuotedCredPattern = #"""
        (?ix)
        (
            "(?:password|passwd|secret|token|api[_-]?key|access[_-]?token|refresh[_-]?token)"
            \s* : \s*
            "
        )
        (?:[^"\\]|\\.)*
        (")
        """#

    /// Bare `k=v` / `k: v` credential dumps
    /// (`password=hunter2`, `password: hunter2`). Optional
    /// surrounding quotes on key / value tolerated; trailing
    /// closing quote (group 2) preserved so JSON stays parse-able
    /// when the bare-token path runs after the strict path on a
    /// mixed-format line.
    ///
    /// **OPSEC (post-v2.0.50):** `&` and `#` added to the value
    /// terminator set. Without them the bare-token matcher
    /// applied to a URL (`?token=abc&user=alice#frag`) consumes
    /// past both separators, clobbering subsequent
    /// non-credential query parameters / URL fragments AND
    /// re-matching the already-redacted `token=***` produced by
    /// the query-string rule below. Bare-token dumps in `naive`
    /// config-load errors and curl `-v` output don't include
    /// `&` or `#` as a value separator, so this is a strict
    /// tightening.
    private static let jsonBareCredPattern = #"""
        (?ix)
        (
            "?(?:password|passwd|secret|token|api[_-]?key|access[_-]?token|refresh[_-]?token)"?
            \s* [:=] \s*
            "?
        )
        [^"\s,&\x23}\r\n]+
        ("?)
        """#

    /// **OPSEC (post-v2.0.50):** query-string credentials —
    /// `?token=abc`, `&api_key=xyz`, `?session=...`. URL
    /// shape: leading `?` or `&`, the credential key, `=`,
    /// then anything up to the next `&` / whitespace / line
    /// boundary. The previous rule set caught `key=value`
    /// dumps but only when the `=` was the line's primary
    /// separator; an HTTPS URL with `?token=…` embedded
    /// passed through because the URL userinfo rule looks
    /// for `://user:pass@`, not query-string credentials.
    private static let queryStringCredPattern = #"""
        (?ix)
        ([?&]
            (?:token|api[_-]?key|access[_-]?token|refresh[_-]?token|session|auth|password|secret)
            =
        )
        [^&\s\x23]+
        """#

    private struct RedactionRule {
        let regex: NSRegularExpression
        let template: String
    }

    /// `expect` is appropriate here: every pattern below is a
    /// compile-time constant. A failed compile would be a build-
    /// breaking regression caught by the test
    /// `redactionRulesCompile` in
    /// `LifecycleTelemetryRedactionTests`.
    private static let redactionRules: [RedactionRule] = {
        func make(_ pattern: String, template: String) -> RedactionRule {
            // Explicit do/catch (instead of an optional-coalesce)
            // so the regex compile error surfaces in the crash
            // message — a future bad edit shouldn't crash with a
            // generic "regex was nil" but with the actual
            // NSError.localizedDescription. `fatalError` is right
            // because the patterns are compile-time constants; a
            // failure here is a build regression, not a runtime
            // condition.
            let regex: NSRegularExpression
            do {
                regex = try NSRegularExpression(
                    pattern: pattern,
                    options: [.allowCommentsAndWhitespace]
                )
            } catch {
                fatalError(
                    "lifecycle telemetry redaction regex failed to compile: "
                        + "\(pattern); error: \(error.localizedDescription)"
                )
            }
            return RedactionRule(regex: regex, template: template)
        }
        return [
            // Order matters: strict-JSON quoted runs first so the
            // bare-token pass doesn't truncate quoted values at the
            // first comma / space. Authorization re-runs after the
            // JSON pass in case a header-shaped credential appears
            // in a log line that also contains a JSON dump.
            make(userinfoPattern, template: "$1***:***@"),
            make(authHeaderPattern, template: "$1***"),
            make(cookieHeaderPattern, template: "$1***"),
            make(jsonQuotedCredPattern, template: "$1***$2"),
            // Query-string rule MUST run before the bare k=v rule:
            // the bare matcher's value class doesn't include `&`,
            // so a URL like `?token=abc&user=alice` would have its
            // `user=alice` segment clobbered. The query-string
            // matcher's value class terminates at `&`, so by the
            // time the bare matcher sees the line the token is
            // already replaced with `***` and the rest of the
            // query string is structurally intact.
            make(queryStringCredPattern, template: "$1***"),
            make(jsonBareCredPattern, template: "$1***$2"),
            make(authHeaderPattern, template: "$1***"),
        ]
    }()

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
