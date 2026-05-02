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

import Foundation

// MARK: - Profile

/// Wire-format profile shared with the engine. Field names match
/// `core::domain::profile::RawProfile` exactly.
public struct Profile: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public var server: String
    public var username: String
    public var password: String
    public var localPort: String

    public init(
        id: String,
        server: String,
        username: String,
        password: String,
        localPort: String
    ) {
        self.id = id
        self.server = server
        self.username = username
        self.password = password
        self.localPort = localPort
    }

    public static let `default` = Profile(
        id: "default",
        server: "naive.example.com",
        username: "user",
        password: "",
        localPort: "1080"
    )
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

    private enum Tag: String, Decodable {
        case logLine = "log_line"
        case stateChanged = "state_changed"
        case anomaly
        case diagnosticProgress = "diagnostic_progress"
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
        }
    }

    private enum DataKeys: String, CodingKey {
        case source, line, running, reason, detail, step, ok
        case elapsedMs = "elapsed_ms"
    }
}

// MARK: - Responses

/// Discriminated reply payload for a [`CoreRequest`].
public enum CoreResponse: Sendable, Hashable {
    case ack
    case validation(ValidationReport)
    case naiveConfig(json: String)
    case pac(js: String)
    case started(pid: UInt32)
    case stopped
    case diagnostic(DiagnosticReport)
    case latency(LatencyReport)

    private enum Tag: String, Decodable {
        case ack
        case validation
        case naiveConfig = "naive_config"
        case pac
        case started
        case stopped
        case diagnostic
        case latency
    }

    private enum FlatKeys: String, CodingKey {
        case type, json, js, pid
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
        case .naiveConfig:
            self = .naiveConfig(json: try flat.decode(String.self, forKey: .json))
        case .pac:
            self = .pac(js: try flat.decode(String.self, forKey: .js))
        case .started:
            self = .started(pid: try flat.decode(UInt32.self, forKey: .pid))
        case .stopped:
            self = .stopped
        case .diagnostic:
            self = .diagnostic(try DiagnosticReport(from: decoder))
        case .latency:
            self = .latency(try LatencyReport(from: decoder))
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
public enum CoreRequest: Sendable, Hashable {
    case validateProfile(Profile)
    case generateNaiveConfig(Profile)
    case generatePac(directDomains: [String], port: UInt16)
    case startProxy(binaryPath: String, configPath: String, port: UInt16)
    case stopProxy
    case runDiagnostics
    case runLatencyTest(mode: ProxyTestMode)
    case shutdown

    public var method: String {
        switch self {
        case .validateProfile: "validate_profile"
        case .generateNaiveConfig: "generate_naive_config"
        case .generatePac: "generate_pac"
        case .startProxy: "start_proxy"
        case .stopProxy: "stop_proxy"
        case .runDiagnostics: "run_diagnostics"
        case .runLatencyTest: "run_latency_test"
        case .shutdown: "shutdown"
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
        case .stopProxy, .runDiagnostics, .shutdown:
            try container.encodeNil(forKey: .params)
        case .validateProfile(let profile),
            .generateNaiveConfig(let profile):
            try container.encode(ProfileEnvelope(profile: profile), forKey: .params)
        case .generatePac(let domains, let port):
            try container.encode(GeneratePacParams(directDomains: domains, port: port), forKey: .params)
        case .startProxy(let binary, let config, let port):
            try container.encode(
                StartProxyParams(binaryPath: binary, configPath: config, port: port),
                forKey: .params
            )
        case .runLatencyTest(let mode):
            try container.encode(LatencyParams(mode: mode), forKey: .params)
        }
    }
}

private struct ProfileEnvelope: Encodable {
    let profile: Profile
}

private struct GeneratePacParams: Encodable {
    let directDomains: [String]
    let port: UInt16

    enum CodingKeys: String, CodingKey {
        case directDomains = "direct_domains"
        case port
    }
}

private struct StartProxyParams: Encodable {
    let binaryPath: String
    let configPath: String
    let port: UInt16

    enum CodingKeys: String, CodingKey {
        case binaryPath = "binary_path"
        case configPath = "config_path"
        case port
    }
}

private struct LatencyParams: Encodable {
    let mode: ProxyTestMode
}
