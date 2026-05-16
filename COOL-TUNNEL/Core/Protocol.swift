// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
// Core/Protocol.swift
//
// Swift Codable mirror of the Rust crate's `protocol` module
// (`core/src/protocol.rs`). Each type below maps one-to-one onto the
// wire-format JSON exchanged with the `cool-tunnel-core` engine.
//
// The wire format is newline-delimited JSON: each frame is one JSON object
// on its own line. Naming follows the Swift API Design Guidelines (camelCase
// case names, descriptive argument labels) while CodingKeys translate to the
// snake_case the Rust side uses.
//
// **v3.0.0 (sub-phase F):** the wire shape pivots from NaiveProxy
// basic-auth (`{username, password}`) to sing-box VLESS+Reality
// (`{username, uuid, reality { public_key, dest_host, short_id }}`).
// `generate_naive_config` / `generate_pac` are gone; sing-box client
// config replaces them via `generate_singbox_config`. The proxy
// liveness probe and debug-handshake stdout/stderr fields rename
// `naive_*` → `singbox_*`. `coreProtocolVersion` bumps `1 → 2`.

import Foundation

/// Wire-format protocol version this Swift build expects from the
/// engine. Compared against the engine's compiled-in
/// `cool_tunnel_core::protocol::PROTOCOL_VERSION` during
/// `CoreClient.start()`. Bump in lock-step with the Rust constant on
/// any breaking change to the JSON-over-stdio frame shapes — additive
/// changes (new request variants, new optional fields) do not require
/// a bump.
///
/// **v3.0.0 (sub-phase F):** bumped `1 → 2` because the `Credentials`
/// payload shape changed from `{username, password}` to
/// `{username, uuid, reality}` and the `generate_naive_config` /
/// `generate_pac` methods were dropped in favour of
/// `generate_singbox_config`.
public let coreProtocolVersion: UInt32 = 2

// MARK: - Profile

/// Reality handshake parameters carried inline on a [`Profile`].
///
/// The wire shape uses snake_case (`public_key`, `dest_host`,
/// `short_id`) to match the Rust core's `RawReality`; the Swift
/// field names are camelCase per Swift's API Design Guidelines.
///
/// All three fields are credential-shaped — `publicKey` and
/// `shortId` carry transport-layer secret material the rendered
/// sing-box config plugs into its VLESS outbound. `destHost` is
/// the cover-site FQDN (e.g. `www.microsoft.com`); leakage there
/// is operator-fingerprinting metadata rather than account
/// takeover, but the lifecycle telemetry redactor still scrubs it
/// when the rendered config or stderr happens to include it.
public struct ProfileReality: Sendable, Codable, Hashable {
    /// X25519 public key, base64url. Plugs into the sing-box
    /// VLESS outbound's `tls.reality.public_key` field; the server-
    /// side `singbox-core` config holds the matching private key.
    public var publicKey: String
    /// Cover-site FQDN used as the Reality SNI on the
    /// `tls.server_name` field. Operator picks: `www.microsoft.com`,
    /// `www.apple.com`, `www.cloudflare.com`.
    public var destHost: String
    /// Reality `short_id` (hex, even length, 0–16 chars). Empty
    /// string is the conventional "no challenge" sentinel — the
    /// server-side `singbox-core` config emits that default when
    /// the operator hasn't configured explicit short_ids.
    public var shortId: String

    public init(publicKey: String, destHost: String, shortId: String) {
        self.publicKey = publicKey
        self.destHost = destHost
        self.shortId = shortId
    }

    private enum CodingKeys: String, CodingKey {
        case publicKey = "public_key"
        case destHost = "dest_host"
        case shortId = "short_id"
    }

    /// Empty placeholder used by `Profile.default` so the new-
    /// profile UX surfaces "please paste your subscription URL"
    /// rather than failing engine validation with an opaque
    /// "reality.public_key must not be empty".
    public static let empty = ProfileReality(publicKey: "", destHost: "", shortId: "")
}

/// Wire-format profile shared with the engine. The core fields
/// (id / server / username / uuid / reality / localPort) match
/// `core::domain::profile::RawProfile` exactly; `subscriptionURL`
/// is a Swift-only persistence field that the Rust deserializer
/// silently ignores (no `#[serde(deny_unknown_fields)]` on the
/// Rust side). Carried on the Profile so a profile imported via
/// a subscription URL remembers its source — the auto-sync flow
/// uses it to re-fetch when the engine reports an auth failure
/// against the cached credentials.
///
/// **v3.0.0 (sub-phase F):** `password` (NaiveProxy basic-auth)
/// replaced by `uuid` (VLESS user_id — the per-account
/// credential) plus a `reality` block carrying the transport-
/// layer secret material the rendered sing-box config plugs into
/// its VLESS+Reality outbound.
public struct Profile: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public var server: String
    public var username: String
    /// VLESS user_id (RFC 4122 UUID). v3.0.0 successor to the v2.x
    /// `password` field — UUID is the actual VLESS auth credential.
    public var uuid: String
    /// Reality handshake parameters (public_key + dest_host +
    /// short_id). Required for the engine to render a working
    /// sing-box client config; `Profile.isStartable` gates Start
    /// on non-empty `publicKey` + `destHost` (shortId may legally
    /// be empty).
    public var reality: ProfileReality
    public var localPort: String
    /// Subscription URL the profile was last imported from, if
    /// any. `nil` for hand-entered profiles; non-nil for profiles
    /// imported via the "Import from subscription URL" flow.
    /// Persisted alongside the rest of the profile so a future
    /// auto-sync can re-fetch credentials transparently when the
    /// upstream rotates the credential and the cached value is
    /// no longer accepted.
    public var subscriptionURL: String?

    public init(
        id: String,
        server: String,
        username: String,
        uuid: String,
        reality: ProfileReality,
        localPort: String,
        subscriptionURL: String? = nil
    ) {
        self.id = id
        self.server = server
        self.username = username
        self.uuid = uuid
        self.reality = reality
        self.localPort = localPort
        self.subscriptionURL = subscriptionURL
    }

    public static let `default` = Profile(
        id: "default",
        server: "proxy.example.com",
        username: "user",
        uuid: "",
        reality: .empty,
        localPort: "1080"
    )

    /// True when every required field is filled AND every
    /// shape-validated field is well-formed. Drives the Start
    /// button's enabled state in `ControlPanelView` so the user
    /// can't launch the engine against a half-filled or
    /// malformed profile (the engine would otherwise spawn
    /// `sing-box` with garbage input, fail to authenticate or
    /// bind, and surface as a generic `× upstream_via_socks` in
    /// the diagnostics — confusing the user about what went
    /// wrong).
    ///
    /// Whitespace-only entries count as empty. `uuid` is also
    /// trimmed: a pure-whitespace UUID is almost always a typo,
    /// and the engine's parser would reject it on the next round
    /// anyway. `reality.shortId` may legally be empty (the
    /// "no challenge" sentinel the server emits when the operator
    /// hasn't set explicit short_ids).
    ///
    /// **v3.0.0 (sub-phase F):** the password gate is now a
    /// uuid + reality.publicKey + reality.destHost gate. A v2.x
    /// profile in-place upgraded across the v3.0.0 boundary loses
    /// access to its NaiveProxy `password`; this gate keeps Start
    /// disabled until the user re-imports via subscription URL,
    /// which populates the v3.0.0 credentials cleanly.
    public var isStartable: Bool {
        serverValidation == .valid
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && !uuid.trimmingCharacters(in: .whitespaces).isEmpty
            && !reality.publicKey.trimmingCharacters(in: .whitespaces).isEmpty
            && !reality.destHost.trimmingCharacters(in: .whitespaces).isEmpty
            && localPortValue != nil
    }

    /// **v2.0.30 (Defensive Input Logic):** parses `localPort` as
    /// a `UInt16` in the range `[1024, 65535]`. Returns `nil` for
    /// any non-numeric, out-of-range, or blank input.
    ///
    /// We refuse ports below 1024 because `sing-box` binding to
    /// a well-known port requires `setuid root` privileges the app
    /// neither has nor should have; the system proxy
    /// `networksetup` happily accepts any port, so without this
    /// gate the operator would see "Connected" while every
    /// browser request silently failed. The conventional local
    /// SOCKS port is 1080.
    public var localPortValue: UInt16? {
        let trimmed = localPort.trimmingCharacters(in: .whitespaces)
        guard let port = UInt16(trimmed), port >= 1024 else {
            return nil
        }
        return port
    }

    /// **v2.0.30 (Defensive Input Logic):** validates the `server`
    /// field against the upstream proxy's wire-shape contract —
    /// bare host or `host:port`, no scheme, no path. Returns the
    /// verdict so the UI can render a precise inline caption
    /// ("remove the https:// prefix") instead of a generic
    /// "bad server."
    ///
    /// Pairs with [`Profile.normaliseServer`], which auto-strips
    /// the scheme and path on paste so the operator's "Good Deed"
    /// is to fix the messy paste, not just complain about it.
    public var serverValidation: ServerValidation {
        let trimmed = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        // Scheme prefix? `^[a-zA-Z][a-zA-Z0-9+.-]*://` matches
        // the RFC-3986 scheme grammar (so we catch `http://`,
        // `https://`, `vless://`, etc.).
        if let schemeRange = trimmed.range(
            of: #"^[a-zA-Z][a-zA-Z0-9+.\-]*://"#, options: .regularExpression)
        {
            let scheme = String(trimmed[..<schemeRange.upperBound])
            return .hasScheme(scheme)
        }
        // Path component?
        if trimmed.contains("/") {
            return .hasPath
        }
        // Strip optional `:port` suffix before hostname-shape
        // check. The port part itself is NOT what `localPort`
        // gates on — that one is the local SOCKS port; this is
        // the upstream proxy server's port. Engine accepts
        // either form.
        let host: String
        if let lastColon = trimmed.lastIndex(of: ":") {
            let portPart = String(trimmed[trimmed.index(after: lastColon)...])
            if UInt16(portPart) != nil {
                host = String(trimmed[..<lastColon])
            } else {
                host = trimmed
            }
        } else {
            host = trimmed
        }
        // Loose RFC-1123 hostname check — labels are separated by
        // dots, alphanumerics + hyphens, no leading/trailing dot,
        // total ≤ 253 chars. The engine's own resolver will
        // reject anything bizarre at start; we just want to catch
        // obvious typos here.
        guard !host.isEmpty,
            host.count <= 253,
            !host.hasPrefix("."), !host.hasSuffix("."),
            host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" })
        else {
            return .malformed(reason: "invalid hostname")
        }
        return .valid
    }

    /// **v2.0.30 (Defensive Input Logic):** the "Good Deed" half
    /// of the input contract — auto-strips a scheme prefix
    /// (`https?://`, `vless://`, …) and any trailing path
    /// from a pasted URL. Used by `ConnectionFormView`'s
    /// `.onChange(of:)` so the field self-corrects on the next
    /// runloop tick after a paste.
    ///
    /// Idempotent: calling on an already-bare hostname returns
    /// the input verbatim (modulo whitespace trimming).
    public static func normaliseServer(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let schemeRange = s.range(
            of: #"^[a-zA-Z][a-zA-Z0-9+.\-]*://"#, options: .regularExpression)
        {
            s = String(s[schemeRange.upperBound...])
        }
        if let slash = s.firstIndex(of: "/") {
            s = String(s[..<slash])
        }
        return s
    }
}

/// **v2.0.30 (Defensive Input Logic):** verdict from
/// [`Profile.serverValidation`]. The associated values carry
/// enough context for `ConnectionFormView` to render a precise
/// inline caption instead of a generic "bad server."
public enum ServerValidation: Sendable, Equatable {
    /// Bare hostname or `host:port` — engine-acceptable.
    case valid
    /// Trimmed input is empty. Treated as "still typing" by the
    /// UI (no red caption shown for this case).
    case empty
    /// Pasted with a scheme prefix; the captured string is the
    /// matched prefix verbatim ("https://", "vless://", …)
    /// so the caption can quote it back to the user.
    case hasScheme(String)
    /// Contains a `/` — looks like the user pasted a URL with a
    /// path. Auto-stripped by `normaliseServer`.
    case hasPath
    /// Other format failure. The reason is a one-line lowercase
    /// noun phrase suitable for inlining in a sentence.
    case malformed(reason: String)
}

// MARK: - Modes

/// Active proxy mode. Mirrors `core::domain::ProxyMode`.
public enum ProxyMode: String, Sendable, Codable, CaseIterable, Hashable {
    case stopped
    case smart
    case global
    case localOnly = "local_only"

    public var title: String {
        switch self {
        case .stopped: "Stopped"
        case .smart: "Smart Mode"
        case .global: "Global Proxy"
        case .localOnly: "Local Only"
        }
    }

    public var requiresListener: Bool { self != .stopped }
}

/// Mode used by the latency-test diagnostic. Mirrors `core::domain::ProxyTestMode`.
public enum ProxyTestMode: String, Sendable, Codable, CaseIterable, Hashable {
    case smart
    case global

    public var title: String {
        switch self {
        case .smart: "Smart"
        case .global: "Global"
        }
    }
}

// MARK: - Events

/// Source stream of a `LogLine` event.
public enum LogSource: String, Sendable, Codable, Hashable {
    case stdout
    case stderr
}

/// Reason a connection-monitor anomaly was raised.
public enum AnomalyReason: String, Sendable, Codable, Hashable {
    case listeningOutsideLoopback = "listening_outside_loopback"
    case tooManyEstablished = "too_many_established"
    case tooManyLocalClients = "too_many_local_clients"
    case tooManyRemote = "too_many_remote"
}

/// One unsolicited engine event.
public enum CoreEvent: Sendable, Hashable {
    case logLine(source: LogSource, line: String)
    case stateChanged(running: Bool)
    case anomaly(reason: AnomalyReason, detail: String)
    /// `elapsedMs` is the wall-clock duration of the step in ms.
    /// Defaults to 0 when the engine omits it (older binaries).
    case diagnosticProgress(step: String, ok: Bool, elapsedMs: UInt64)
    /// Lightweight monitor snapshot emitted by the engine on each
    /// successful lsof tick. Currently ignored client-side; retained
    /// because the engine still emits it.
    case trafficSnapshot(pid: UInt32, established: UInt32, localClients: UInt32, remote: UInt32)

    private enum Tag: String, Decodable {
        case logLine = "log_line"
        case stateChanged = "state_changed"
        case anomaly
        case diagnosticProgress = "diagnostic_progress"
        case trafficSnapshot = "traffic_snapshot"
    }

    private enum FrameKeys: String, CodingKey {
        case event
        case data
    }
}

extension CoreEvent: Decodable {
    public init(from decoder: any Decoder) throws {
        let frame = try decoder.container(keyedBy: FrameKeys.self)
        let tag = try frame.decode(Tag.self, forKey: .event)
        let data = try frame.nestedContainer(keyedBy: DataKeys.self, forKey: .data)
        switch tag {
        case .logLine:
            self = try .logLine(
                source: data.decode(LogSource.self, forKey: .source),
                line: data.decode(String.self, forKey: .line)
            )
        case .stateChanged:
            self = try .stateChanged(running: data.decode(Bool.self, forKey: .running))
        case .anomaly:
            self = try .anomaly(
                reason: data.decode(AnomalyReason.self, forKey: .reason),
                detail: data.decode(String.self, forKey: .detail)
            )
        case .diagnosticProgress:
            // `elapsed_ms` is optional on the wire so older engine
            // builds (which never sent it) keep decoding cleanly. Fall
            // back to 0 — the renderer treats that as "no timing".
            let elapsed =
                try data.decodeIfPresent(UInt64.self, forKey: .elapsedMs) ?? 0
            self = try .diagnosticProgress(
                step: data.decode(String.self, forKey: .step),
                ok: data.decode(Bool.self, forKey: .ok),
                elapsedMs: elapsed
            )
        case .trafficSnapshot:
            self = try .trafficSnapshot(
                pid: data.decode(UInt32.self, forKey: .pid),
                established: data.decode(UInt32.self, forKey: .established),
                localClients: data.decode(UInt32.self, forKey: .localClients),
                remote: data.decode(UInt32.self, forKey: .remote)
            )
        }
    }

    private enum DataKeys: String, CodingKey {
        case source, line, running, reason, detail, step, ok
        case pid, established, remote
        case elapsedMs = "elapsed_ms"
        case localClients = "local_clients"
    }
}

// MARK: - Responses

/// Discriminated reply payload for a [`CoreRequest`].
///
/// **v3.0.0 (sub-phase F):** wire tag renames in lock-step with
/// the Rust side:
/// - `naive_config` → `singbox_config`
/// - `naive_liveness` → `singbox_liveness`
///
/// The `pac` variant is dropped (Rust crate's `GeneratePac` was
/// removed in sub-phase D); smart-mode PAC text is now produced
/// in-process on the Swift side by `TunnelOrchestrator`.
public enum CoreResponse: Sendable, Hashable {
    case ack
    case validation(ValidationReport)
    /// `generate_singbox_config` reply carrying the rendered
    /// sing-box client `config.json` as a pretty-printed string.
    case singboxConfig(json: String)
    case started(pid: UInt32)
    case stopped
    case diagnostic(DiagnosticReport)
    case latency(LatencyReport)
    /// `probe_singbox_live` reply: `running` is the canonical
    /// "is the engine still alive" flag the orchestrator routes
    /// on; `pid` is for diagnostic logging only.
    case singboxLiveness(running: Bool, pid: UInt32?)
    /// `hello` reply carrying the engine's compiled-in
    /// `protocolVersion` and `engineVersion`. The Swift caller
    /// compares `protocolVersion` against `coreProtocolVersion`
    /// during `CoreClient.start()` and refuses to proceed on a
    /// hard mismatch. `engineVersion` is purely informational —
    /// surfaced in support diagnostics so a bug report ties to
    /// an exact Rust binary.
    case helloReply(protocolVersion: UInt32, engineVersion: String)
    /// `probe_server` reply. Carries a structured reachability
    /// report rather than a transport error so the UI can render
    /// timing alongside an unreachable result.
    case probe(ProbeReport)
    case debugHandshake(DebugHandshakeReport)

    private enum Tag: String, Decodable {
        case ack
        case validation
        case singboxConfig = "singbox_config"
        case started
        case stopped
        case diagnostic
        case latency
        case singboxLiveness = "singbox_liveness"
        case helloReply = "hello_reply"
        case probe
        case debugHandshake = "debug_handshake"
    }

    private enum FlatKeys: String, CodingKey {
        case type, json, pid, running
        case protocolVersion = "protocol_version"
        case engineVersion = "engine_version"
    }
}

extension CoreResponse: Decodable {
    public init(from decoder: any Decoder) throws {
        let flat = try decoder.container(keyedBy: FlatKeys.self)
        let tag = try flat.decode(Tag.self, forKey: .type)
        switch tag {
        case .ack:
            self = .ack
        case .validation:
            self = .validation(try ValidationReport(from: decoder))
        case .singboxConfig:
            self = .singboxConfig(json: try flat.decode(String.self, forKey: .json))
        case .started:
            self = .started(pid: try flat.decode(UInt32.self, forKey: .pid))
        case .stopped:
            self = .stopped
        case .diagnostic:
            self = .diagnostic(try DiagnosticReport(from: decoder))
        case .latency:
            self = .latency(try LatencyReport(from: decoder))
        case .singboxLiveness:
            self = .singboxLiveness(
                running: try flat.decode(Bool.self, forKey: .running),
                pid: try flat.decodeIfPresent(UInt32.self, forKey: .pid)
            )
        case .helloReply:
            self = .helloReply(
                protocolVersion: try flat.decode(UInt32.self, forKey: .protocolVersion),
                engineVersion: try flat.decode(String.self, forKey: .engineVersion)
            )
        case .probe:
            // The Rust side flattens `Probe(ProbeReport)` into the
            // outer payload via `#[serde(tag = "type")]`, so the
            // probe report's fields live alongside `"type"` rather
            // than nested under a `data` key. Decoding the report
            // straight from `decoder` (the same container that
            // already produced the tag) picks them up.
            self = .probe(try ProbeReport(from: decoder))
        case .debugHandshake:
            self = .debugHandshake(try DebugHandshakeReport(from: decoder))
        }
    }
}

/// Result of `validate_profile`.
public struct ValidationReport: Sendable, Codable, Hashable {
    public let ok: Bool
    public let reason: String?
}

/// Diagnostic-run result.
public struct DiagnosticReport: Sendable, Codable, Hashable {
    public let probes: [ProbeResult]
}

public struct ProbeResult: Sendable, Codable, Hashable {
    public let name: String
    public let ok: Bool
    public let detail: String
    public let durationMs: UInt64

    private enum CodingKeys: String, CodingKey {
        case name, ok, detail
        case durationMs = "duration_ms"
    }
}

public struct LatencyReport: Sendable, Codable, Hashable {
    public let samples: [LatencySample]
}

public struct LatencySample: Sendable, Codable, Hashable {
    public let url: String
    public let ok: Bool
    public let elapsedMs: Double
    public let dnsMs: Double
    public let connectMs: Double
    public let tlsMs: Double
    public let firstByteMs: Double
    public let notes: String

    private enum CodingKeys: String, CodingKey {
        case url, ok, notes
        case elapsedMs = "elapsed_ms"
        case dnsMs = "dns_ms"
        case connectMs = "connect_ms"
        case tlsMs = "tls_ms"
        case firstByteMs = "first_byte_ms"
    }
}

/// Pre-flight reachability probe result. Mirrors
/// `cool_tunnel_core::protocol::ProbeReport`.
///
/// `dnsResolveMs` and `tcpConnectMs` are reported independently so
/// the UI can distinguish a slow resolver (long DNS, short TCP,
/// `reachable == true`) from a blocked port (long or zero TCP,
/// `reachable == false`, `error` describes the failure).
public struct ProbeReport: Sendable, Codable, Hashable {
    /// The probed `host:port` after default-port substitution.
    public let server: String
    /// `true` when DNS resolved and the TCP connect completed.
    public let reachable: Bool
    /// DNS resolution wall-clock in milliseconds.
    public let dnsResolveMs: Double
    /// TCP connect wall-clock in milliseconds. Zero when DNS
    /// failed and the connect step did not run.
    public let tcpConnectMs: Double
    /// Free-form failure detail when `reachable` is `false`.
    public let error: String?

    private enum CodingKeys: String, CodingKey {
        case server, reachable, error
        case dnsResolveMs = "dns_resolve_ms"
        case tcpConnectMs = "tcp_connect_ms"
    }
}

/// Result of [`CoreRequest.debugHandshake`]. Carries the
/// byte-level evidence the operator-facing classifier reads.
///
/// **v3.0.0 (sub-phase F):** the stdout / stderr field names
/// renamed `naive_*` → `singbox_*` in lock-step with the engine
/// pivot. The byte semantics still describe the temporary SOCKS5
/// listener the engine spun up for the diagnostic (Rust side
/// retained the historical names like `local_sent_hex` /
/// `local_received_hex` verbatim; only the supervisor's
/// stdout/stderr fields renamed).
public struct DebugHandshakeReport: Sendable, Codable, Hashable {
    public let server: String
    public let target: String
    public let ok: Bool
    public let connectOk: Bool
    public let postConnectReceivedBytes: UInt64
    public let elapsedMs: UInt64
    public let localSentHex: String
    public let localReceivedHex: String
    /// Redacted stdout lines captured from the temporary
    /// `sing-box` child the engine spawned for the diagnostic.
    public let singboxStdout: [String]
    /// Redacted stderr lines captured from the temporary
    /// `sing-box` child. Carries any handshake-rejection
    /// signature the engine surfaced (e.g.
    /// "reality handshake failed").
    public let singboxStderr: [String]
    public let error: String?

    public init(
        server: String,
        target: String,
        ok: Bool,
        connectOk: Bool,
        postConnectReceivedBytes: UInt64,
        elapsedMs: UInt64,
        localSentHex: String,
        localReceivedHex: String,
        singboxStdout: [String],
        singboxStderr: [String],
        error: String?
    ) {
        self.server = server
        self.target = target
        self.ok = ok
        self.connectOk = connectOk
        self.postConnectReceivedBytes = postConnectReceivedBytes
        self.elapsedMs = elapsedMs
        self.localSentHex = localSentHex
        self.localReceivedHex = localReceivedHex
        self.singboxStdout = singboxStdout
        self.singboxStderr = singboxStderr
        self.error = error
    }

    private enum CodingKeys: String, CodingKey {
        case server, target, ok, error
        case connectOk = "connect_ok"
        case postConnectReceivedBytes = "post_connect_received_bytes"
        case elapsedMs = "elapsed_ms"
        case localSentHex = "local_sent_hex"
        case localReceivedHex = "local_received_hex"
        case singboxStdout = "singbox_stdout"
        case singboxStderr = "singbox_stderr"
    }
}

/// One-line failure classification derived from a
/// [`DebugHandshakeReport`]. Lets the orchestrator surface an
/// actionable banner ("server accepted credentials but cannot
/// reach the destination — check VPS egress") instead of the
/// raw byte-level breakdown that requires an operator to read
/// hex to interpret.
///
/// **v3.0.0 note:** the historical byte-shape patterns (`HTTP/1.1
/// 200`, `HTTP/1.1 407`) describe NaiveProxy's HTTP-CONNECT
/// frames. The v3.0.0 engine's `debug_handshake` probe drives one
/// SOCKS5 connect through a temporary `sing-box` child instead;
/// the post-CONNECT byte stream is a SOCKS5 reply rather than an
/// HTTP response. The Swift classifier is deliberately preserved
/// across the rename so historical support transcripts still
/// parse — for new v3.0.0 reports the byte-shape patterns won't
/// match and every non-success falls into `.other`, surfacing the
/// raw `singboxStderr` lines instead. A follow-up retunes this
/// for the SOCKS5 byte shape; sub-phase F covers the rename only.
public enum DebugHandshakeFailureClass: String, Sendable, Hashable, Codable {
    /// TCP / TLS to the proxy did not establish. The classic
    /// "wrong server", "VPS down", or "ISP-blocking-port-443"
    /// signature.
    case connectFailed = "connect_failed"

    /// Proxy answered the CONNECT with HTTP 407 — credentials
    /// rejected. Distinguishable from `vpsEgressBlocked` because
    /// the response bytes start with `HTTP/1.1 407` rather than
    /// `HTTP/1.1 200`. **v3.0.0:** historical NaiveProxy pattern;
    /// preserved for support-transcript parsing.
    case proxyAuthRejected = "proxy_auth_rejected"

    /// Proxy accepted CONNECT (HTTP 200 OK from forward_proxy /
    /// NaiveProxy), then the connection RSTed without any bytes
    /// from the upstream destination. The VPS reached the proxy
    /// daemon and credentials worked, but the VPS itself can't
    /// reach the target — egress firewall, ISP-level filter,
    /// IPv6-only routing to a destination the VPS can't talk
    /// to, DNS pointing at an unreachable IP, or the
    /// destination blocked at the VPS's network.
    case vpsEgressBlocked = "vps_egress_blocked"

    /// Unclassified failure shape — non-2xx response that isn't
    /// 407, partial bytes received before the error, or a
    /// failure mode the byte-level evidence doesn't fit. Fall
    /// through to the raw byte dump for diagnosis. **v3.0.0:**
    /// most VLESS+Reality handshake failures land here until the
    /// classifier learns the new SOCKS5 byte shape.
    case other = "other"

    /// User-facing one-line explanation. Read by
    /// `TunnelOrchestrator.runDebugHandshake` to surface as an
    /// `appendInfo` banner after the byte-level report.
    public var operatorHint: String {
        switch self {
        case .connectFailed:
            return
                "Couldn't reach the proxy. Verify the server hostname / port, "
                + "or test from the VPS shell with: "
                + "`curl -v --max-time 5 https://<your-domain>`"
        case .proxyAuthRejected:
            return
                "Server rejected the credentials (HTTP 407). If you imported "
                + "via a subscription URL, try re-importing — the panel may "
                + "have rotated the UUID. Otherwise check the Server / "
                + "Username / UUID fields in Settings."
        case .vpsEgressBlocked:
            return
                "Server accepted credentials but cannot reach the destination. "
                + "This is a VPS-side issue. On the VPS run: "
                + "`curl -v --max-time 5 https://www.google.com/generate_204` "
                + "— if it RSTs the same way, your VPS's egress to that "
                + "destination is blocked (datacenter firewall, ISP filter, "
                + "IPv6 routing, or a local iptables rule)."
        case .other:
            return
                "Handshake failed in an unrecognised shape. Read the byte "
                + "dump above for clues; `singbox_stderr` lines (if any) are "
                + "the sing-box child's own diagnostic output."
        }
    }
}

extension DebugHandshakeReport {
    /// Classify a non-success handshake report into one of four
    /// actionable failure modes. Returns `nil` when the handshake
    /// actually succeeded (`ok == true`); the caller doesn't
    /// surface a hint in that case.
    public var failureClassification: DebugHandshakeFailureClass? {
        guard !ok else { return nil }
        if !connectOk { return .connectFailed }

        // connectOk == true → look at what came back from the
        // proxy. The byte format is space-separated lowercase hex
        // (e.g. "48 54 54 50 2f 31 2e 31 20 32 30 30 …" for
        // "HTTP/1.1 200 …"). Strip the spaces for a stable
        // prefix-compare.
        let hex = localReceivedHex.replacingOccurrences(of: " ", with: "").lowercased()

        // "HTTP/1.1 407" = 48 54 54 50 2f 31 2e 31 20 34 30 37
        if hex.hasPrefix("485454502f312e3120343037") {
            return .proxyAuthRejected
        }

        // "HTTP/1.1 200" = 48 54 54 50 2f 31 2e 31 20 32 30 30
        // — proxy accepted CONNECT but post_connect_received==0
        //   AND the error string matches a reset / refused / closed
        //   pattern → VPS-egress-blocked.
        let accepted200 = hex.hasPrefix("485454502f312e3120323030")
        if accepted200,
            postConnectReceivedBytes == 0,
            Self.isConnectionResetError(error)
        {
            return .vpsEgressBlocked
        }

        return .other
    }

    /// True when the error string from a debug-handshake failure
    /// indicates an upstream-pipe teardown (connection RSTed,
    /// closed, refused, or aborted). Used by
    /// `failureClassification` to disambiguate
    /// `vpsEgressBlocked` from `other`.
    ///
    /// Permissive on purpose — the underlying engine emits the
    /// error string verbatim from the OS-level `std::io::Error`,
    /// and the same root cause (egress blocked, destination
    /// refused, peer RST) shows up under several legitimate
    /// strings across macOS / Linux / different Rust versions.
    /// False positives turn into the actionable hint "check VPS
    /// egress" — which is still the right next operator step
    /// even if the underlying issue turns out to be something
    /// else.
    nonisolated public static func isConnectionResetError(_ error: String?) -> Bool {
        guard let error = error else { return false }
        let lower = error.lowercased()
        if lower.contains("reset by peer") { return true }
        if lower.contains("connection reset") { return true }
        if lower.contains("econnreset") { return true }
        if lower.contains("os error 54") { return true }  // macOS ECONNRESET
        if lower.contains("os error 104") { return true }  // Linux ECONNRESET
        if lower.contains("connection refused") { return true }
        if lower.contains("connection aborted") { return true }
        if lower.contains("broken pipe") { return true }
        if lower.contains("unexpected eof") { return true }
        return false
    }
}

/// Failure detail accompanying [`CoreOutbound.error`].
public struct ErrorPayload: Sendable, Codable, Error, Hashable {
    public let code: String
    public let message: String
}

// MARK: - Outbound frames

/// One frame received from the engine's stdout.
public enum CoreOutbound: Sendable {
    case response(id: UInt64, result: CoreResponse)
    case error(id: UInt64, error: ErrorPayload)
    case event(CoreEvent)

    private enum Kind: String, Decodable {
        case response, error, event
    }

    private enum Keys: String, CodingKey {
        case kind, id, result, error
    }
}

extension CoreOutbound: Decodable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .response:
            self = try .response(
                id: container.decode(UInt64.self, forKey: .id),
                result: container.decode(CoreResponse.self, forKey: .result)
            )
        case .error:
            self = try .error(
                id: container.decode(UInt64.self, forKey: .id),
                error: container.decode(ErrorPayload.self, forKey: .error)
            )
        case .event:
            self = try .event(CoreEvent(from: decoder))
        }
    }
}

// MARK: - Requests

/// One request sent to the engine. Variant names follow Swift conventions
/// (camelCase); the wire emits snake_case via [`Self.method`] and per-variant
/// param structs.
///
/// **v3.0.0 (sub-phase F):** method renames in lock-step with the
/// Rust side:
/// - `generate_naive_config` → `generate_singbox_config`
/// - `probe_naive_live` → `probe_singbox_live`
///
/// The `generate_pac` variant is dropped (Rust crate's `GeneratePac`
/// was removed in sub-phase D); smart-mode PAC text is generated
/// in-process on the Swift side by `TunnelOrchestrator`.
public enum CoreRequest: Sendable, Hashable {
    case validateProfile(Profile)
    /// Generate the sing-box client `config.json` for the given
    /// validated profile. Successor to v2.x's `generateNaiveConfig`.
    case generateSingboxConfig(Profile)
    /// Spawn the bundled `sing-box` binary and start streaming
    /// its output. `monitorIntervalSecs` overrides the engine's
    /// connection-monitor poll cadence (clamped server-side to
    /// `[1, 60]`); pass `nil` to keep the historical 5-second
    /// default.
    case startProxy(
        binaryPath: String, configPath: String, port: UInt16,
        monitorIntervalSecs: UInt64? = nil
    )
    case stopProxy
    case runDiagnostics
    case runLatencyTest(mode: ProxyTestMode)
    case shutdown
    /// Asks the engine whether its supervised proxy binary is
    /// currently alive. Used by the orchestrator's no-restart
    /// hot-swap path to detect a sing-box crash that happened
    /// during the swap window. The wire-protocol method name is
    /// `probe_singbox_live`; the reply tag is `singbox_liveness`.
    case probeSingboxLive
    /// Wire-protocol handshake. Sent by `CoreClient.start()`
    /// immediately after the subprocess spawns; the engine
    /// replies with `helloReply(protocolVersion:engineVersion:)`
    /// so the client can refuse to proceed on a hard version
    /// mismatch. Older engines that predate this method return
    /// an `invalid_request` error, which `CoreClient` treats as
    /// protocol version 0 (legacy) and accepts.
    case hello
    /// Pre-flight reachability probe against the upstream server
    /// described by `profile`. Resolves DNS and opens a TCP
    /// connection (no TLS or auth). `timeoutSecs` is the
    /// per-step deadline in seconds, clamped server-side to
    /// `[1, 30]`; `nil` defaults to 5.
    case probeServer(profile: Profile, timeoutSecs: UInt64? = nil)
    case debugHandshake(binaryPath: String, profile: Profile, timeoutSecs: UInt64? = nil)

    public var method: String {
        switch self {
        case .validateProfile: "validate_profile"
        case .generateSingboxConfig: "generate_singbox_config"
        case .startProxy: "start_proxy"
        case .stopProxy: "stop_proxy"
        case .runDiagnostics: "run_diagnostics"
        case .runLatencyTest: "run_latency_test"
        case .shutdown: "shutdown"
        case .probeSingboxLive: "probe_singbox_live"
        case .hello: "hello"
        case .probeServer: "probe_server"
        case .debugHandshake: "debug_handshake"
        }
    }
}

/// Wire-format envelope: pairs an [`CoreRequest`] with the caller-chosen `id`.
public struct CoreRequestFrame: Sendable, Encodable {
    public let id: UInt64
    public let request: CoreRequest

    public init(id: UInt64, request: CoreRequest) {
        self.id = id
        self.request = request
    }

    private enum Keys: String, CodingKey {
        case id, method, params
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(id, forKey: .id)
        try container.encode(request.method, forKey: .method)
        switch request {
        case .stopProxy, .runDiagnostics, .shutdown, .probeSingboxLive, .hello:
            try container.encodeNil(forKey: .params)
        case .validateProfile(let profile),
            .generateSingboxConfig(let profile):
            try container.encode(ProfileEnvelope(profile: profile), forKey: .params)
        case .startProxy(let binary, let config, let port, let monitorInterval):
            try container.encode(
                StartProxyParams(
                    binaryPath: binary,
                    configPath: config,
                    port: port,
                    monitorIntervalSecs: monitorInterval
                ),
                forKey: .params
            )
        case .runLatencyTest(let mode):
            try container.encode(LatencyParams(mode: mode), forKey: .params)
        case .probeServer(let profile, let timeoutSecs):
            try container.encode(
                ProbeServerParams(profile: profile, timeoutSecs: timeoutSecs),
                forKey: .params
            )
        case .debugHandshake(let binary, let profile, let timeoutSecs):
            try container.encode(
                DebugHandshakeParams(
                    binaryPath: binary,
                    profile: profile,
                    timeoutSecs: timeoutSecs
                ),
                forKey: .params
            )
        }
    }
}

private struct ProfileEnvelope: Encodable {
    let profile: Profile
}

private struct StartProxyParams: Encodable {
    let binaryPath: String
    let configPath: String
    let port: UInt16
    let monitorIntervalSecs: UInt64?

    enum CodingKeys: String, CodingKey {
        case binaryPath = "binary_path"
        case configPath = "config_path"
        case port
        case monitorIntervalSecs = "monitor_interval_secs"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(binaryPath, forKey: .binaryPath)
        try container.encode(configPath, forKey: .configPath)
        try container.encode(port, forKey: .port)
        // Omit `monitor_interval_secs` from the wire when nil so an
        // older engine that doesn't know the field deserializes the
        // frame cleanly (it would error on a `null` for an unknown
        // key only if `deny_unknown_fields` were set; the engine
        // doesn't set that today, but keeping the wire minimal is
        // forward-compatible regardless).
        try container.encodeIfPresent(monitorIntervalSecs, forKey: .monitorIntervalSecs)
    }
}

private struct LatencyParams: Encodable {
    let mode: ProxyTestMode
}

private struct ProbeServerParams: Encodable {
    let profile: Profile
    let timeoutSecs: UInt64?

    enum CodingKeys: String, CodingKey {
        case profile
        case timeoutSecs = "timeout_secs"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(profile, forKey: .profile)
        try container.encodeIfPresent(timeoutSecs, forKey: .timeoutSecs)
    }
}

private struct DebugHandshakeParams: Encodable {
    let binaryPath: String
    let profile: Profile
    let timeoutSecs: UInt64?

    enum CodingKeys: String, CodingKey {
        case binaryPath = "binary_path"
        case profile
        case timeoutSecs = "timeout_secs"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(binaryPath, forKey: .binaryPath)
        try container.encode(profile, forKey: .profile)
        try container.encodeIfPresent(timeoutSecs, forKey: .timeoutSecs)
    }
}
